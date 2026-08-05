"""FastAPI-Routen fuer den vertikalen Prototyp (Phase 1).

Bewusst schlank gehalten: keine Nutzerkonten, keine DB. MIDI-Sessions leben nur
in-memory (siehe state.py); Audiodateien werden nie auf Platte behalten (siehe
pitch_detection.pyin, das seine Temp-Datei sofort wieder loescht).
"""

from __future__ import annotations

import uuid

from fastapi import APIRouter, Depends, File, HTTPException, Request, UploadFile

from backend.config import MAX_AUDIO_SECONDS, PITCH_FMAX_HZ, PITCH_FMIN_HZ
from backend.midi_analysis import list_track_candidates, load_midi, track_pitch_curve
from backend.pitch_detection import PitchAnalysisError, analyze_pitch

from .rate_limit import enforce_upload_rate_limit
from .state import MIDI_SESSIONS

router = APIRouter(prefix="/api")

MAX_MIDI_UPLOAD_BYTES = 5 * 1024 * 1024  # 5 MB, MIDI-Dateien sind winzig
MAX_AUDIO_UPLOAD_BYTES = 40 * 1024 * 1024  # grosszuegig fuer 20-60s unkomprimiertes WAV


def _reject_oversized_content_length(request: Request, max_bytes: int) -> None:
    """Verwirft offensichtlich zu grosse Uploads anhand des Content-Length-Headers,
    bevor der komplette Body in den Speicher gelesen wird. Kein Ersatz fuer die
    Pruefung der tatsaechlichen Groesse nach dem Lesen (Header ist nicht faelschungssicher
    z.B. bei Chunked Transfer Encoding), sondern eine billige Vorabbremse fuer den
    haeufigen Fall eines regulaer angegebenen, zu grossen Bodys."""
    content_length = request.headers.get("content-length")
    if content_length is None:
        return
    try:
        declared_bytes = int(content_length)
    except ValueError:
        return
    if declared_bytes > max_bytes:
        raise HTTPException(status_code=413, detail="Datei ist unerwartet gross.")


@router.post("/midi/upload", dependencies=[Depends(enforce_upload_rate_limit)])
def upload_midi(request: Request, file: UploadFile = File(...)) -> dict:
    _reject_oversized_content_length(request, MAX_MIDI_UPLOAD_BYTES)
    data = file.file.read()
    if len(data) > MAX_MIDI_UPLOAD_BYTES:
        raise HTTPException(status_code=413, detail="MIDI-Datei ist unerwartet gross.")

    try:
        pm = load_midi(data)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    candidates = list_track_candidates(pm)
    session_id = uuid.uuid4().hex
    MIDI_SESSIONS.set(session_id, pm)

    return {
        "session_id": session_id,
        "candidates": [c.to_dict() for c in candidates],
        "has_plausible_vocal_track": any(c.plausible for c in candidates),
    }


@router.get("/midi/{session_id}/track-curve")
async def get_track_curve(session_id: str, track_index: int, transpose: int = 0) -> dict:
    pm = MIDI_SESSIONS.get(session_id)
    if pm is None:
        raise HTTPException(
            status_code=404,
            detail="MIDI-Session nicht gefunden oder abgelaufen - bitte Datei erneut hochladen.",
        )
    try:
        curve = track_pitch_curve(pm, track_index, transpose_semitones=transpose)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    return {"curve": curve}


@router.delete("/midi/{session_id}")
async def clear_midi_session(session_id: str) -> dict:
    MIDI_SESSIONS.pop(session_id)
    return {"ok": True}


@router.post("/audio/analyze", dependencies=[Depends(enforce_upload_rate_limit)])
def analyze_audio(request: Request, file: UploadFile = File(...)) -> dict:
    _reject_oversized_content_length(request, MAX_AUDIO_UPLOAD_BYTES)
    data = file.file.read()
    if len(data) > MAX_AUDIO_UPLOAD_BYTES:
        raise HTTPException(status_code=413, detail="Audiodatei ist unerwartet gross.")

    try:
        curve = analyze_pitch(
            data,
            filename_hint=file.filename or "upload.wav",
            max_seconds=MAX_AUDIO_SECONDS,
            fmin=PITCH_FMIN_HZ,
            fmax=PITCH_FMAX_HZ,
        )
    except PitchAnalysisError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    return {"curve": curve}

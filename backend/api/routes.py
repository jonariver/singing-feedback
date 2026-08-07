"""FastAPI-Routen fuer den vertikalen Prototyp (Phase 1).

Bewusst schlank gehalten: keine Nutzerkonten, keine DB. MIDI-Sessions leben nur
in-memory (siehe state.py); Audiodateien werden nie auf Platte behalten (siehe
pitch_detection.pyin, das seine Temp-Datei sofort wieder loescht).
"""

from __future__ import annotations

import uuid

from fastapi import APIRouter, Depends, File, Form, HTTPException, Request, Response, UploadFile
from pydantic import BaseModel

from backend.audio_io import AudioDecodeError, load_audio_signal
from backend.config import (
    DTW_FRAME_RATE_HZ,
    MAX_AUDIO_SECONDS,
    MAX_SCORE_CURVE_FRAMES,
    MAX_SCORE_REQUEST_BYTES,
    PITCH_FMAX_HZ,
    PITCH_FMIN_HZ,
)
from backend.midi_analysis import list_track_candidates, load_midi, synthesize_track_preview, track_pitch_curve
from backend.pitch_detection import PitchAnalysisError, analyze_pitch, pitch_curve_from_signal
from backend.feedback import FeedbackUnavailableError, generate_feedback
from backend.scoring import score_performance
from backend.sync import (
    align_curves,
    duration_ratio_exceeds_limit,
    onset_envelope_from_midi_track,
    onset_envelope_from_signal,
)

from .rate_limit import enforce_upload_rate_limit
from .state import MIDI_SESSIONS

router = APIRouter(prefix="/api")

MAX_MIDI_UPLOAD_BYTES = 5 * 1024 * 1024  # 5 MB, MIDI-Dateien sind winzig
MAX_AUDIO_UPLOAD_BYTES = 80 * 1024 * 1024  # 300s Stereo-44.1kHz-WAV-Upload braucht ~53MB


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


@router.get("/midi/{session_id}/track-preview")
def get_track_preview(session_id: str, track_index: int, transpose: int = 0) -> Response:
    pm = MIDI_SESSIONS.get(session_id)
    if pm is None:
        raise HTTPException(
            status_code=404,
            detail="MIDI-Session nicht gefunden oder abgelaufen - bitte Datei erneut hochladen.",
        )
    try:
        wav_bytes = synthesize_track_preview(pm, track_index, transpose_semitones=transpose)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    return Response(content=wav_bytes, media_type="audio/wav")


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


@router.post("/sync/align", dependencies=[Depends(enforce_upload_rate_limit)])
def sync_align(
    request: Request,
    sung_audio: UploadFile = File(...),
    session_id: str | None = Form(None),
    track_index: int | None = Form(None),
    transpose: int = Form(0),
    reference_audio: UploadFile | None = File(None),
) -> dict:
    _reject_oversized_content_length(request, 2 * MAX_AUDIO_UPLOAD_BYTES)

    sung_bytes = sung_audio.file.read()
    if len(sung_bytes) > MAX_AUDIO_UPLOAD_BYTES:
        raise HTTPException(status_code=413, detail="Audiodatei ist unerwartet gross.")

    try:
        y_sung, sr_sung, _ = load_audio_signal(sung_bytes, sung_audio.filename or "sung.wav", MAX_AUDIO_SECONDS)
    except AudioDecodeError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    sung_curve = pitch_curve_from_signal(y_sung, sr_sung, fmin=PITCH_FMIN_HZ, fmax=PITCH_FMAX_HZ)
    sung_envelope = onset_envelope_from_signal(y_sung, sr_sung, frame_rate_hz=DTW_FRAME_RATE_HZ)

    if reference_audio is not None:
        ref_bytes = reference_audio.file.read()
        if len(ref_bytes) > MAX_AUDIO_UPLOAD_BYTES:
            raise HTTPException(status_code=413, detail="Referenz-Audiodatei ist unerwartet gross.")
        try:
            y_ref, sr_ref, _ = load_audio_signal(
                ref_bytes, reference_audio.filename or "reference.wav", MAX_AUDIO_SECONDS,
            )
        except AudioDecodeError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        target_curve = pitch_curve_from_signal(y_ref, sr_ref, fmin=PITCH_FMIN_HZ, fmax=PITCH_FMAX_HZ)
        target_envelope = onset_envelope_from_signal(y_ref, sr_ref, frame_rate_hz=DTW_FRAME_RATE_HZ)
    elif session_id is not None and track_index is not None:
        pm = MIDI_SESSIONS.get(session_id)
        if pm is None:
            raise HTTPException(
                status_code=404,
                detail="MIDI-Session nicht gefunden oder abgelaufen - bitte Datei erneut hochladen.",
            )
        try:
            target_curve = track_pitch_curve(pm, track_index, transpose_semitones=transpose)
            target_envelope = onset_envelope_from_midi_track(pm, track_index, frame_rate_hz=DTW_FRAME_RATE_HZ)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
    else:
        raise HTTPException(
            status_code=400,
            detail="Entweder session_id und track_index oder reference_audio angeben.",
        )

    target_duration = target_curve[-1]["t"] if target_curve else 0.0
    sung_duration = sung_curve[-1]["t"] if sung_curve else 0.0
    if duration_ratio_exceeds_limit(target_duration, sung_duration):
        raise HTTPException(
            status_code=400,
            detail=(
                "Zielmelodie ist deutlich laenger als die Aufnahme "
                f"({target_duration:.0f}s vs. {sung_duration:.0f}s) - Ausrichtung nicht "
                "sinnvoll moeglich. Bitte einen kuerzeren Ausschnitt der Zielmelodie waehlen "
                "oder laenger singen."
            ),
        )

    result = align_curves(
        target_curve, target_envelope, sung_curve, sung_envelope,
        envelope_frame_rate_hz=DTW_FRAME_RATE_HZ,
    )
    return {"target_curve": target_curve, **result}


class ScoreRequest(BaseModel):
    target_curve: list[dict]
    sung_curve: list[dict]  # muss die AUSGERICHTETE Kurve sein (aligned_t vorhanden)


@router.post("/score", dependencies=[Depends(enforce_upload_rate_limit)])
def score(request: Request, body: ScoreRequest) -> dict:
    _reject_oversized_content_length(request, MAX_SCORE_REQUEST_BYTES)
    if len(body.target_curve) > MAX_SCORE_CURVE_FRAMES or len(body.sung_curve) > MAX_SCORE_CURVE_FRAMES:
        raise HTTPException(status_code=413, detail="Kurve ist unerwartet lang.")
    try:
        result = score_performance(body.target_curve, body.sung_curve)
    except (ValueError, KeyError, TypeError) as exc:
        raise HTTPException(
            status_code=400,
            detail="Kurvendaten sind unvollständig oder ungültig.",
        ) from exc
    return {"score": result}


class FeedbackRequest(BaseModel):
    score: dict  # ScoreResult, wie von /api/score unter "score" zurueckgegeben


@router.post("/feedback", dependencies=[Depends(enforce_upload_rate_limit)])
def feedback(request: Request, body: FeedbackRequest) -> dict:
    _reject_oversized_content_length(request, MAX_SCORE_REQUEST_BYTES)
    try:
        result = generate_feedback(body.score)
    except FeedbackUnavailableError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except (KeyError, TypeError) as exc:
        raise HTTPException(
            status_code=400,
            detail="score-Daten sind unvollständig oder ungültig.",
        ) from exc
    return {"feedback": result}

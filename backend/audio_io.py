"""Gemeinsames Audio-Decoding fuer pitch_detection und sync (Phase 3).

Vorher steckte diese Logik ausschliesslich in pitch_detection/pyin.py; ausgelagert,
damit backend/sync dieselbe dekodierte Signalform bekommt, ohne dieselben
Audiobytes ein zweites Mal zu dekodieren.
"""

from __future__ import annotations

import os
import tempfile

import av
import librosa
import numpy as np

_ALLOWED_SUFFIXES = {".wav", ".mp3", ".flac", ".ogg", ".m4a", ".webm"}


class AudioDecodeError(Exception):
    """Audiodatei konnte nicht gelesen oder dekodiert werden."""


def _safe_suffix(filename_hint: str) -> str:
    suffix = os.path.splitext(filename_hint or "")[1].lower()
    return suffix if suffix in _ALLOWED_SUFFIXES else ".wav"


def _load_with_pyav(path: str) -> tuple[np.ndarray, int]:
    """Dekodiert Formate, die soundfile/audioread nicht lesen koennen (z.B. AAC-in-M4A,
    Opus-in-WebM von Mobile-/Browser-Recordern). PyAV bringt eigene ffmpeg-Libs im Wheel
    mit, braucht also anders als audioreads ffmpeg-Fallback keinen System-ffmpeg-Binary."""
    container = av.open(path)
    try:
        stream = container.streams.audio[0]
        sr = stream.codec_context.sample_rate
        resampler = av.AudioResampler(format="fltp", layout="mono", rate=sr)
        chunks = [
            rframe.to_ndarray()
            for frame in container.decode(stream)
            for rframe in resampler.resample(frame)
        ]
    finally:
        container.close()

    if not chunks:
        raise ValueError("PyAV hat keine Audio-Frames dekodiert.")
    y = np.concatenate(chunks, axis=1)[0].astype(np.float32)
    return y, sr


def load_audio_signal(
    audio_bytes: bytes,
    filename_hint: str = "upload.wav",
    max_seconds: float = 90.0,
) -> tuple[np.ndarray, int]:
    """Dekodiert Audio-Rohbytes zu (Samples, Sample-Rate), auf max_seconds gekappt.

    Die Audiodatei wird nur in einer temporaeren Datei zwischengehalten und danach
    sofort geloescht - keine dauerhafte Speicherung (siehe Datenschutz-Leitplanke).

    ACHTUNG: Der Anfang des dekodierten Signals wird hier NICHT getrimmt/verschoben
    (nur das Ende wird bei max_seconds gekappt). Das Feature "Sprung zur Zeitstelle
    in der Aufnahme" (Mobile-Feedback-Karten) setzt genau darauf: sungCurve.t
    entspricht 1:1 der Abspielposition in denselben Rohbytes. Wird hier je Start-
    Trimming/Offset eingefuehrt, bricht dieses Feature still.
    """
    if not audio_bytes:
        raise AudioDecodeError("Keine Audiodaten empfangen.")

    tmp_path: str | None = None
    try:
        with tempfile.NamedTemporaryFile(suffix=_safe_suffix(filename_hint), delete=False) as tmp:
            tmp.write(audio_bytes)
            tmp_path = tmp.name

        try:
            y, sr = librosa.load(tmp_path, sr=None, mono=True)
        except Exception:
            try:
                y, sr = _load_with_pyav(tmp_path)
            except Exception as exc:
                raise AudioDecodeError(
                    f"Audiodatei konnte nicht dekodiert werden (Format nicht unterstuetzt?): {exc}"
                ) from exc
    finally:
        if tmp_path and os.path.exists(tmp_path):
            os.remove(tmp_path)

    if y.size == 0:
        raise AudioDecodeError("Audiodatei enthaelt keine Samples.")

    max_samples = int(max_seconds * sr)
    if y.shape[0] > max_samples:
        y = y[:max_samples]

    return y, sr

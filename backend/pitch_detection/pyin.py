"""Tonhoehenerkennung fuer die Gesangsaufnahme via librosa/pYIN (Phase 1).

Bewusst pYIN statt CREPE (siehe Plan-Annahmen): keine TensorFlow/Torch-Abhaengigkeit,
laeuft rein auf der CPU, fuer 20-60s-Ausschnitte ausreichend schnell. Das Modul ist
so gekapselt, dass ein Austausch gegen ein anderes Verfahren spaeter moeglich ist,
ohne die aufrufende API zu aendern.
"""

from __future__ import annotations

import os
import tempfile

import librosa
import numpy as np

_ALLOWED_SUFFIXES = {".wav", ".mp3", ".flac", ".ogg", ".m4a", ".webm"}


class PitchAnalysisError(Exception):
    """Aufnahme konnte nicht gelesen oder analysiert werden."""


def _safe_suffix(filename_hint: str) -> str:
    suffix = os.path.splitext(filename_hint or "")[1].lower()
    return suffix if suffix in _ALLOWED_SUFFIXES else ".wav"


def analyze_pitch(
    audio_bytes: bytes,
    filename_hint: str = "upload.wav",
    max_seconds: float = 90.0,
    fmin: float = 65.0,
    fmax: float = 1050.0,
    frame_rate_hz: float = 100.0,
) -> list[dict]:
    """Liefert die gesungene Tonhoehe als Zeitreihe: [{t, hz|None, voiced, confidence}].

    hz ist None fuer unstimmhafte/stille Abschnitte (Pausen, Atmen, Konsonanten).
    Die Audiodatei wird nur in einer temporaeren Datei zwischengehalten und danach
    sofort geloescht - keine dauerhafte Speicherung (siehe Datenschutz-Leitplanke).
    """
    if not audio_bytes:
        raise PitchAnalysisError("Keine Audiodaten empfangen.")

    tmp_path: str | None = None
    try:
        with tempfile.NamedTemporaryFile(suffix=_safe_suffix(filename_hint), delete=False) as tmp:
            tmp.write(audio_bytes)
            tmp_path = tmp.name

        try:
            y, sr = librosa.load(tmp_path, sr=None, mono=True)
        except Exception as exc:
            raise PitchAnalysisError(
                f"Audiodatei konnte nicht dekodiert werden (Format nicht unterstuetzt?): {exc}"
            ) from exc
    finally:
        if tmp_path and os.path.exists(tmp_path):
            os.remove(tmp_path)

    if y.size == 0:
        raise PitchAnalysisError("Audiodatei enthaelt keine Samples.")

    max_samples = int(max_seconds * sr)
    if y.shape[0] > max_samples:
        y = y[:max_samples]

    hop_length = max(1, int(round(sr / frame_rate_hz)))
    f0, voiced_flag, voiced_prob = librosa.pyin(
        y, fmin=fmin, fmax=fmax, sr=sr, hop_length=hop_length,
    )
    times = librosa.times_like(f0, sr=sr, hop_length=hop_length)

    curve: list[dict] = []
    for t, hz, voiced, prob in zip(times, f0, voiced_flag, voiced_prob):
        is_voiced = bool(voiced) and not np.isnan(hz)
        curve.append({
            "t": round(float(t), 3),
            "hz": round(float(hz), 3) if is_voiced else None,
            "voiced": is_voiced,
            "confidence": round(float(prob), 3) if not np.isnan(prob) else 0.0,
        })
    return curve

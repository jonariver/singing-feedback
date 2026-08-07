"""Tonhoehenerkennung fuer die Gesangsaufnahme via librosa/pYIN (Phase 1).

Bewusst pYIN statt CREPE (siehe Plan-Annahmen): keine TensorFlow/Torch-Abhaengigkeit,
laeuft rein auf der CPU, fuer 20-60s-Ausschnitte ausreichend schnell. Das Modul ist
so gekapselt, dass ein Austausch gegen ein anderes Verfahren spaeter moeglich ist,
ohne die aufrufende API zu aendern.
"""

from __future__ import annotations

import librosa
import numpy as np

from backend.audio_io import AudioDecodeError, load_audio_signal


class PitchAnalysisError(Exception):
    """Aufnahme konnte nicht gelesen oder analysiert werden."""


def pitch_curve_from_signal(
    y: np.ndarray,
    sr: int,
    fmin: float = 65.0,
    fmax: float = 1050.0,
    frame_rate_hz: float = 100.0,
) -> list[dict]:
    """Liefert die Tonhoehe eines bereits dekodierten Signals als Zeitreihe:
    [{t, hz|None, voiced, confidence}]. hz ist None fuer unstimmhafte/stille
    Abschnitte (Pausen, Atmen, Konsonanten)."""
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


def analyze_pitch(
    audio_bytes: bytes,
    filename_hint: str = "upload.wav",
    max_seconds: float = 90.0,
    fmin: float = 65.0,
    fmax: float = 1050.0,
    frame_rate_hz: float = 100.0,
) -> dict:
    """Liefert {"curve": [{t, hz|None, voiced, confidence}], "truncated": bool,
    "original_duration_seconds": float}.

    Dekodiert die Audiobytes (temporaer, wird sofort danach geloescht - siehe
    Datenschutz-Leitplanke) und delegiert die eigentliche Tonhoehenberechnung an
    pitch_curve_from_signal(). "truncated"/"original_duration_seconds" kommen direkt
    von load_audio_signal() durch (siehe docs/superpowers/specs/
    2026-08-07-longer-recordings-design.md).
    """
    try:
        y, sr, original_duration_seconds = load_audio_signal(audio_bytes, filename_hint, max_seconds)
    except AudioDecodeError as exc:
        raise PitchAnalysisError(str(exc)) from exc
    curve = pitch_curve_from_signal(y, sr, fmin=fmin, fmax=fmax, frame_rate_hz=frame_rate_hz)
    return {
        "curve": curve,
        "truncated": original_duration_seconds > max_seconds,
        "original_duration_seconds": round(original_duration_seconds, 1),
    }

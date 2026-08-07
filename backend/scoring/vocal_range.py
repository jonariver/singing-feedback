"""Stimmumfang der Aufnahme (Phase 4-Rest, Teil 2): rein informative Kennzahl ueber
die ganze gesungene Aufnahme, unabhaengig von Noten-Segmentierung/DTW-Ausrichtung -
Tonhoehe aendert sich durch die Zeitausrichtung nicht, daher genuegt die rohe
sung_curve."""

from __future__ import annotations

from backend.config import (
    VOCAL_RANGE_HIGH_PERCENTILE,
    VOCAL_RANGE_LOW_PERCENTILE,
    VOCAL_RANGE_MAX_TRIM_FRAMES,
    VOCAL_RANGE_MIN_VOICED_FRAMES,
)
from backend.scoring.notes import hz_to_midi_note

NOT_APPLICABLE_VOCAL_RANGE = {
    "applicable": False, "min_hz": None, "max_hz": None, "min_midi_note": None, "max_midi_note": None,
}


def compute_vocal_range(sung_curve: list[dict]) -> dict:
    voiced_hz = sorted(
        frame["hz"] for frame in sung_curve
        if frame.get("voiced") and frame.get("hz") is not None
    )
    if len(voiced_hz) < VOCAL_RANGE_MIN_VOICED_FRAMES:
        return dict(NOT_APPLICABLE_VOCAL_RANGE)

    n = len(voiced_hz)
    low_trim = min(round((VOCAL_RANGE_LOW_PERCENTILE / 100) * n), VOCAL_RANGE_MAX_TRIM_FRAMES)
    high_trim = min(round(((100 - VOCAL_RANGE_HIGH_PERCENTILE) / 100) * n), VOCAL_RANGE_MAX_TRIM_FRAMES)
    min_hz = voiced_hz[low_trim]
    max_hz = voiced_hz[n - 1 - high_trim]
    return {
        "applicable": True,
        "min_hz": round(min_hz, 3),
        "max_hz": round(max_hz, 3),
        "min_midi_note": hz_to_midi_note(min_hz),
        "max_midi_note": hz_to_midi_note(max_hz),
    }

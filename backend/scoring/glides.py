"""Glide-Erkennung (Phase 4-Rest, Teil 1): rutscht der Gesang zu Beginn einer Note
von einer anderen Tonhoehe in den Zielton, statt ihn direkt zu treffen?

Spiegelbildlich zu stability.py's Phrasenend-Drift: dort wird das letzte Zeitfenster
einer Note gegen deren Hauptteil verglichen, hier das ERSTE Zeitfenster (Kopf) gegen
den REST der Note. Nutzt denselben Median-Vergleich (robust gegen einzelne pYIN-
Ausreisser) wie stability.py.
"""

from __future__ import annotations

from backend.config import (
    GLIDE_HEAD_SECONDS,
    GLIDE_MIN_HEAD_FRAMES,
    GLIDE_ONSET_THRESHOLD_CENTS,
)
from backend.scoring.notes import cents_series

NOT_APPLICABLE_GLIDE = {
    "applicable": False, "onset_cents_deviation": None, "flag": False, "direction": None,
}


def compute_glide(note: dict, attributed_frames: list[dict], green_threshold: float) -> dict:
    head_end = min(note["start_t"] + GLIDE_HEAD_SECONDS, note["end_t"])
    series = cents_series(note, attributed_frames)
    head_values = sorted(c for t, c in series if t < head_end)
    rest_values = sorted(c for t, c in series if t >= head_end)
    if len(head_values) < GLIDE_MIN_HEAD_FRAMES or not rest_values:
        return dict(NOT_APPLICABLE_GLIDE)

    head_median = head_values[len(head_values) // 2]
    rest_median = rest_values[len(rest_values) // 2]
    flag = abs(head_median) > GLIDE_ONSET_THRESHOLD_CENTS and abs(rest_median) <= green_threshold
    direction = ("up" if head_median < 0 else "down") if flag else None
    return {
        "applicable": True,
        "onset_cents_deviation": round(head_median, 1),
        "flag": flag,
        "direction": direction,
    }

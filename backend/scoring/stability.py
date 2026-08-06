"""Stabilitaet & Phrasenend-Drift bei gehaltenen Toenen (Phase 4).

Zwei DISJUNKTE Zeitfenster (Hauptteil ohne die letzten DRIFT_TAIL_SECONDS fuer
Stabilitaet, ausschliesslich die letzten DRIFT_TAIL_SECONDS fuer Drift) statt
eines gemeinsamen Fensters: das ist der Grund, warum eine konstant falsch
gesungene Note (durchgehend z.B. -40 Cent, aber kein Drift) korrekt von einer am
Ende absackenden Note (stabiler Hauptteil, aber Drift im letzten Viertel)
unterschieden wird - mit einem gemeinsamen Fenster wuerde die zweite Note faelsch-
licherweise auch als "instabil" gelten, weil die Streuung ueber die ganze Note
durch den Drift-Anteil aufgeblaeht wuerde.
"""

from __future__ import annotations

from backend.config import (
    DRIFT_FLAG_THRESHOLD_CENTS,
    DRIFT_TAIL_SECONDS,
    HELD_NOTE_MIN_DURATION_SECONDS,
    STABILITY_MAD_THRESHOLD_CENTS,
    STABILITY_ONSET_TRIM_SECONDS,
)
from backend.scoring.notes import hz_to_cents

_NOT_APPLICABLE_STABILITY = {"applicable": False, "mad_cents": None, "flag": False}
_NOT_APPLICABLE_DRIFT = {"applicable": False, "drift_cents": None, "flag": False, "direction": None}


def is_held_note(note: dict) -> bool:
    return (note["end_t"] - note["start_t"]) >= HELD_NOTE_MIN_DURATION_SECONDS


def _cents_series(note: dict, attributed_frames: list[dict]) -> list[tuple[float, float]]:
    """[(aligned_t, cents_deviation), ...] fuer stimmhafte zugeordnete Frames, nach
    Zeit sortiert."""
    target_cents = hz_to_cents(note["hz"])
    series = [
        (frame["aligned_t"], hz_to_cents(frame["hz"]) - target_cents)
        for frame in attributed_frames
        if frame.get("voiced") and frame.get("hz") is not None
    ]
    series.sort(key=lambda pair: pair[0])
    return series


def compute_stability(note: dict, attributed_frames: list[dict]) -> dict:
    if not is_held_note(note):
        return dict(_NOT_APPLICABLE_STABILITY)

    body_start = note["start_t"] + STABILITY_ONSET_TRIM_SECONDS
    body_end = note["end_t"] - DRIFT_TAIL_SECONDS
    body_values = sorted(
        c for t, c in _cents_series(note, attributed_frames) if body_start <= t < body_end
    )
    if not body_values:
        return dict(_NOT_APPLICABLE_STABILITY)

    median_value = body_values[len(body_values) // 2]
    abs_deviations = sorted(abs(v - median_value) for v in body_values)
    mad = abs_deviations[len(abs_deviations) // 2]
    return {
        "applicable": True,
        "mad_cents": round(mad, 1),
        "flag": mad > STABILITY_MAD_THRESHOLD_CENTS,
    }


def compute_phrase_end_drift(note: dict, attributed_frames: list[dict]) -> dict:
    if not is_held_note(note):
        return dict(_NOT_APPLICABLE_DRIFT)

    body_start = note["start_t"] + STABILITY_ONSET_TRIM_SECONDS
    body_end = note["end_t"] - DRIFT_TAIL_SECONDS
    series = _cents_series(note, attributed_frames)
    body_values = sorted(c for t, c in series if body_start <= t < body_end)
    tail_values = sorted(c for t, c in series if t >= body_end)
    if not body_values or not tail_values:
        return dict(_NOT_APPLICABLE_DRIFT)

    body_median = body_values[len(body_values) // 2]
    tail_median = tail_values[len(tail_values) // 2]
    drift = tail_median - body_median
    flag = abs(drift) > DRIFT_FLAG_THRESHOLD_CENTS
    direction = ("down" if drift < 0 else "up") if flag else None
    return {"applicable": True, "drift_cents": round(drift, 1), "flag": flag, "direction": direction}

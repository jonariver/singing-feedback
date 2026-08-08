"""Pausen/Atemstellen-Erkennung (Phase 4-Rest, Teil 3): macht der Gesang mitten in
einer gehaltenen Zielnote eine (Atem-)Pause, obwohl die Zielmelodie dort keine Pause
vorsieht?

Nutzt dieselben Bausteine wie stability.py: is_held_note()-Gate und
STABILITY_ONSET_TRIM_SECONDS (schliesst den kurzen Konsonanten-Anlauf einer Note aus,
damit ein normaler Wortanlaut wie "T"/"K" nicht faelschlich als Pause zaehlt). Anders
als notes.py's cents_series() filtert diese Funktion NICHT auf stimmhafte Frames - hier
wird gerade nach den unstimmhaften Laeufen gesucht, die cents_series() verwirft.
"""

from __future__ import annotations

from backend.config import PAUSE_MIN_GAP_SECONDS, STABILITY_ONSET_TRIM_SECONDS
from backend.scoring.stability import is_held_note

NOT_APPLICABLE_PAUSE = {"applicable": False, "gap_seconds": None, "flag": False}


def compute_pause(note: dict, attributed_frames: list[dict]) -> dict:
    if not is_held_note(note):
        return dict(NOT_APPLICABLE_PAUSE)

    window_start = note["start_t"] + STABILITY_ONSET_TRIM_SECONDS
    window_end = note["end_t"]
    frames = sorted(
        (
            f for f in attributed_frames
            if f.get("aligned_t") is not None and window_start <= f["aligned_t"] < window_end
        ),
        key=lambda f: f["aligned_t"],
    )
    if not frames:
        return dict(NOT_APPLICABLE_PAUSE)

    longest_gap = 0.0
    run_start = None
    run_end = None
    for frame in frames:
        t = frame["aligned_t"]
        unvoiced = not frame.get("voiced") or frame.get("hz") is None
        if unvoiced:
            if run_start is None:
                run_start = t
            run_end = t
        elif run_start is not None:
            longest_gap = max(longest_gap, run_end - run_start)
            run_start = None
    if run_start is not None:
        longest_gap = max(longest_gap, run_end - run_start)

    return {
        "applicable": True,
        "gap_seconds": round(longest_gap, 3),
        "flag": longest_gap > PAUSE_MIN_GAP_SECONDS,
    }

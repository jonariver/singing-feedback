"""Timing / Einsatzabweichung (Phase 4)."""

from __future__ import annotations

from backend.config import (
    TIMING_MAX_SEARCH_SECONDS,
    TIMING_OK_THRESHOLD_MS,
    TIMING_ONSET_WINDOW_FRAMES,
)


def classify_timing(deviation_ms: float) -> str:
    if deviation_ms > TIMING_OK_THRESHOLD_MS:
        return "too_early"
    if deviation_ms < -TIMING_OK_THRESHOLD_MS:
        return "too_late"
    return "on_time"


def compute_onset_deviation_ms(
    sung_curve: list[dict],
    note: dict,
    window_frames: int = TIMING_ONSET_WINDOW_FRAMES,
    max_search_seconds: float = TIMING_MAX_SEARCH_SECONDS,
) -> float | None:
    """Median von (aligned_t - t) * 1000 der `window_frames` stimmhaften Gesangs-
    Frames, deren aligned_t am naechsten am Notenanfang liegt (aber hoechstens
    max_search_seconds entfernt - verhindert, dass ein komplett unbesungener Note ein
    Timing-Urteil von einer voellig unabhaengigen, weit entfernten Note "erbt"). Sucht
    ueber die GESAMTE sung_curve (nicht nur die dieser Note zugeordneten Frames), da
    der naechste stimmhafte Einsatz auch knapp ausserhalb des Zuordnungsfensters
    liegen kann (z.B. bei einer zu frueh gesungenen Note)."""
    candidates = [
        f for f in sung_curve
        if f.get("voiced")
        and f.get("aligned_t") is not None
        and abs(f["aligned_t"] - note["start_t"]) <= max_search_seconds
    ]
    if not candidates:
        return None
    candidates.sort(key=lambda f: abs(f["aligned_t"] - note["start_t"]))
    nearest = candidates[:window_frames]
    deltas = sorted((f["aligned_t"] - f["t"]) * 1000.0 for f in nearest)
    return deltas[len(deltas) // 2]

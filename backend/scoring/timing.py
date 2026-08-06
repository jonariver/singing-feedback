"""Timing / Einsatzabweichung (Phase 4)."""

from __future__ import annotations

from backend.config import TIMING_OK_THRESHOLD_MS, TIMING_ONSET_WINDOW_FRAMES


def classify_timing(deviation_ms: float) -> str:
    if deviation_ms > TIMING_OK_THRESHOLD_MS:
        return "too_early"
    if deviation_ms < -TIMING_OK_THRESHOLD_MS:
        return "too_late"
    return "on_time"


def compute_onset_deviation_ms(
    sung_curve: list[dict], note: dict, window_frames: int = TIMING_ONSET_WINDOW_FRAMES,
) -> float | None:
    """Median von (aligned_t - t) * 1000 der `window_frames` stimmhaften Gesangs-
    Frames, deren aligned_t am naechsten am Notenanfang liegt. Sucht ueber die
    GESAMTE sung_curve (nicht nur die dieser Note zugeordneten Frames), da der
    naechste stimmhafte Einsatz auch knapp ausserhalb des Zuordnungsfensters
    liegen kann (z.B. bei einer zu frueh gesungenen Note)."""
    voiced = [f for f in sung_curve if f.get("voiced") and f.get("aligned_t") is not None]
    if not voiced:
        return None
    voiced.sort(key=lambda f: abs(f["aligned_t"] - note["start_t"]))
    nearest = voiced[:window_frames]
    deltas = sorted((f["aligned_t"] - f["t"]) * 1000.0 for f in nearest)
    return deltas[len(deltas) // 2]

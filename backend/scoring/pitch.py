"""Cent-Abweichung & verfehlte Zielnoten (Phase 4)."""

from __future__ import annotations

from backend.config import (
    MISSED_NOTE_CENTS_THRESHOLD,
    MISSED_NOTE_MIN_COVERAGE_FRACTION,
    STABILITY_ONSET_TRIM_SECONDS,
)
from backend.scoring.notes import hz_to_cents


def classify_cents(value: float, green_threshold: float, yellow_threshold: float) -> str:
    magnitude = abs(value)
    if magnitude <= green_threshold:
        return "green"
    if magnitude <= yellow_threshold:
        return "yellow"
    return "red"


def _voiced_deviations(note: dict, attributed_frames: list[dict]) -> list[float]:
    onset_cutoff = note["start_t"] + STABILITY_ONSET_TRIM_SECONDS
    target_cents = hz_to_cents(note["hz"])
    deviations = []
    for frame in attributed_frames:
        if not frame.get("voiced") or frame.get("hz") is None:
            continue
        if frame["aligned_t"] < onset_cutoff:
            continue
        deviations.append(hz_to_cents(frame["hz"]) - target_cents)
    return deviations


def compute_cents_deviation(
    note: dict, attributed_frames: list[dict], green_threshold: float, yellow_threshold: float,
) -> dict | None:
    """{'value': float, 'classification': str} oder None, wenn keine stimmhaften
    Frames zugeordnet werden konnten (dann greift stattdessen is_missed())."""
    deviations = sorted(_voiced_deviations(note, attributed_frames))
    if not deviations:
        return None
    median_value = deviations[len(deviations) // 2]
    classification = classify_cents(median_value, green_threshold, yellow_threshold)
    return {"value": round(median_value, 1), "classification": classification}


def compute_coverage_fraction(note: dict, attributed_frames: list[dict], frame_rate_hz: float = 100.0) -> float:
    """Anteil der Ziel-Zeitraster-Buckets im Notenfenster, die von mindestens einem
    stimmhaften zugeordneten Frame abgedeckt sind. Dedupliziert nach Bucket (nicht
    nach Roh-Frame-Anzahl), da DTW mehrere Gesangs-Frames auf denselben Ziel-Frame
    abbilden kann."""
    step = 1.0 / frame_rate_hz
    expected_buckets = max(1, round((note["end_t"] - note["start_t"]) / step))
    covered_buckets: set[int] = set()
    for frame in attributed_frames:
        if not frame.get("voiced") or frame.get("hz") is None:
            continue
        bucket = round((frame["aligned_t"] - note["start_t"]) / step)
        bucket = max(0, min(bucket, expected_buckets - 1))
        covered_buckets.add(bucket)
    return min(1.0, len(covered_buckets) / expected_buckets)


def is_missed(coverage_fraction: float, cents_value: float | None) -> bool:
    if coverage_fraction < MISSED_NOTE_MIN_COVERAGE_FRACTION:
        return True
    if cents_value is not None and abs(cents_value) > MISSED_NOTE_CENTS_THRESHOLD:
        return True
    return False

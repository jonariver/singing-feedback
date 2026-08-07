"""Bewertungs-Engine Orchestrator (Phase 4): fasst Noten-Segmentierung und alle
vier Kernpaket-Metriken zu einem strukturierten Ergebnis zusammen."""

from __future__ import annotations

from backend.scoring.glides import NOT_APPLICABLE_GLIDE, compute_glide
from backend.scoring.notes import attribute_sung_frames, segment_target_notes
from backend.scoring.pitch import compute_cents_deviation, compute_coverage_fraction, is_missed
from backend.scoring.stability import compute_phrase_end_drift, compute_stability, is_held_note
from backend.scoring.timing import classify_timing, compute_onset_deviation_ms

_PROBLEM_TAG_TIMING = "timingprobleme"
_PROBLEM_TAG_DRIFT = "absinkende_phrasenenden"
_PROBLEM_TAG_STABILITY = "instabile_lange_toene"
_PROBLEM_TAG_MISSED = "unsaubere_einsaetze"
_PROBLEM_TAG_GLIDE = "haeufiges_hineingleiten"


def score_performance(
    target_curve: list[dict], sung_curve: list[dict], frame_rate_hz: float = 100.0,
) -> dict:
    if sung_curve and any("aligned_t" not in frame for frame in sung_curve):
        raise ValueError(
            "sung_curve-Frames ohne 'aligned_t' - bitte zuerst align_curves() aufrufen."
        )

    target_notes = segment_target_notes(target_curve, frame_rate_hz=frame_rate_hz)

    notes: list[dict] = []
    problem_tags: set[str] = set()
    cents_green = cents_yellow = cents_red = 0
    missed_count = timing_flagged = stability_flagged = drift_flagged = glide_flagged = 0

    for i, note in enumerate(target_notes):
        is_last = i == len(target_notes) - 1
        attributed = attribute_sung_frames(sung_curve, note, is_last)

        coverage = compute_coverage_fraction(note, attributed, frame_rate_hz)
        cents = compute_cents_deviation(note, attributed)
        cents_value = cents["value"] if cents else None
        missed = is_missed(coverage, cents_value)

        onset_ms = compute_onset_deviation_ms(sung_curve, note)
        timing_classification = "on_time"
        if not missed and onset_ms is not None:
            timing_classification = classify_timing(onset_ms)

        stability = compute_stability(note, attributed)
        drift = compute_phrase_end_drift(note, attributed)
        glide = (
            compute_glide(note, attributed)
            if not missed
            and cents
            and cents["classification"] in ("green", "yellow")
            and timing_classification == "on_time"
            else dict(NOT_APPLICABLE_GLIDE)
        )

        if missed or (cents and cents["classification"] == "red"):
            problem_tags.add(_PROBLEM_TAG_MISSED)
        if timing_classification != "on_time":
            problem_tags.add(_PROBLEM_TAG_TIMING)
            timing_flagged += 1
        if stability["flag"]:
            problem_tags.add(_PROBLEM_TAG_STABILITY)
            stability_flagged += 1
        if drift["flag"]:
            problem_tags.add(_PROBLEM_TAG_DRIFT)
            drift_flagged += 1
        if glide["flag"]:
            problem_tags.add(_PROBLEM_TAG_GLIDE)
            glide_flagged += 1

        if missed:
            missed_count += 1
        elif cents:
            if cents["classification"] == "green":
                cents_green += 1
            elif cents["classification"] == "yellow":
                cents_yellow += 1
            else:
                cents_red += 1

        notes.append({
            "index": note["index"],
            "start_t": note["start_t"],
            "end_t": note["end_t"],
            "target_hz": note["hz"],
            "target_midi_note": note["midi_note"],
            "missed": missed,
            "coverage_fraction": round(coverage, 3),
            "cents_deviation": cents or {"value": None, "classification": "red"},
            "timing": {
                "deviation_ms": round(onset_ms, 1) if onset_ms is not None else None,
                "classification": timing_classification,
            },
            "held": is_held_note(note),
            "stability": stability,
            "phrase_end_drift": drift,
            "glide": glide,
            "sung_t": attributed[0]["t"] if attributed else None,
        })

    note_count = len(notes)
    penalty = (
        missed_count * 100
        + cents_yellow * 20 + cents_red * 45
        + timing_flagged * 15 + stability_flagged * 10 + drift_flagged * 10 + glide_flagged * 10
    )
    overall_score = max(0.0, 100.0 - (penalty / note_count)) if note_count else 0.0

    return {
        "notes": notes,
        "summary": {
            "note_count": note_count,
            "missed_count": missed_count,
            "cents_green": cents_green,
            "cents_yellow": cents_yellow,
            "cents_red": cents_red,
            "timing_flagged_count": timing_flagged,
            "stability_flagged_count": stability_flagged,
            "phrase_end_drift_flagged_count": drift_flagged,
            "glide_flagged_count": glide_flagged,
            "overall_score": round(overall_score, 1),
            "problem_tags": sorted(problem_tags),
        },
    }

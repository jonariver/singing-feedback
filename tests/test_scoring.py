"""Tests fuer die Bewertungs-Engine (Phase 4, Kernpaket)."""

from __future__ import annotations

import pytest

from backend.scoring.notes import attribute_sung_frames, hz_to_cents, segment_target_notes
from backend.scoring.pitch import (
    classify_cents,
    compute_cents_deviation,
    compute_coverage_fraction,
    is_missed,
)
from backend.scoring.timing import classify_timing, compute_onset_deviation_ms


def _flat_curve(hz: float, n_frames: int, start_idx: int = 0, frame_rate_hz: float = 100.0) -> list[dict]:
    step = 1.0 / frame_rate_hz
    return [
        {"t": round((start_idx + i) * step, 3), "hz": hz, "midi_note": None}
        for i in range(n_frames)
    ]


def test_hz_to_cents_reference_a4_is_zero():
    assert hz_to_cents(440.0) == pytest.approx(0.0)
    assert hz_to_cents(880.0) == pytest.approx(1200.0)


def test_segment_target_notes_splits_on_pitch_jump():
    curve = _flat_curve(440.0, 100, start_idx=0) + _flat_curve(880.0, 100, start_idx=100)
    notes = segment_target_notes(curve, frame_rate_hz=100.0)
    assert len(notes) == 2
    assert notes[0]["hz"] == pytest.approx(440.0, abs=0.01)
    assert notes[1]["hz"] == pytest.approx(880.0, abs=0.01)
    assert notes[0]["start_t"] == 0.0
    assert notes[1]["start_t"] == pytest.approx(1.0, abs=0.01)


def test_segment_target_notes_bridges_short_gap():
    # 100ms Luecke (10 Frames) liegt unter dem Bridge-Limit (150ms) - bleibt EINE Note.
    step = 0.01
    curve = []
    for i in range(100):
        hz = None if 45 <= i < 55 else 440.0
        curve.append({"t": round(i * step, 3), "hz": hz, "midi_note": None})
    notes = segment_target_notes(curve, frame_rate_hz=100.0)
    assert len(notes) == 1


def test_segment_target_notes_closes_on_long_gap():
    # 300ms Luecke (30 Frames) liegt ueber dem Bridge-Limit - teilt die Note wirklich.
    step = 0.01
    curve = []
    for i in range(130):
        hz = None if 40 <= i < 70 else 440.0
        curve.append({"t": round(i * step, 3), "hz": hz, "midi_note": None})
    notes = segment_target_notes(curve, frame_rate_hz=100.0)
    assert len(notes) == 2


def test_segment_target_notes_drops_short_segments():
    # Ein 50ms "Segment" (< 120ms Mindestdauer) zwischen zwei echten Noten wird verworfen.
    curve = (
        _flat_curve(440.0, 100, start_idx=0)
        + _flat_curve(500.0, 5, start_idx=100)
        + _flat_curve(660.0, 100, start_idx=105)
    )
    notes = segment_target_notes(curve, frame_rate_hz=100.0)
    assert len(notes) == 2
    assert notes[0]["hz"] == pytest.approx(440.0, abs=0.01)
    assert notes[1]["hz"] == pytest.approx(660.0, abs=0.01)


def test_segment_target_notes_uses_midi_note_field_when_present():
    curve = [{"t": round(i * 0.01, 3), "hz": 261.626, "midi_note": 60} for i in range(100)]
    notes = segment_target_notes(curve, frame_rate_hz=100.0)
    assert len(notes) == 1
    assert notes[0]["midi_note"] == 60


def test_attribute_sung_frames_respects_note_window():
    note = {"index": 0, "start_t": 1.0, "end_t": 2.0, "hz": 440.0, "midi_note": 69}
    sung_curve = [
        {"t": 0.5, "aligned_t": 0.9},   # vor dem Fenster
        {"t": 1.2, "aligned_t": 1.2},   # im Fenster
        {"t": 1.8, "aligned_t": 1.8},   # im Fenster
        {"t": 2.1, "aligned_t": 2.1},   # nach dem Fenster (nicht letzte Note)
    ]
    attributed = attribute_sung_frames(sung_curve, note, is_last_note=False)
    assert [f["t"] for f in attributed] == [1.2, 1.8]


def test_attribute_sung_frames_last_note_has_tail_tolerance():
    note = {"index": 0, "start_t": 1.0, "end_t": 2.0, "hz": 440.0, "midi_note": 69}
    sung_curve = [{"t": 2.2, "aligned_t": 2.2}]  # 0.2s past end, within 0.3s tolerance
    attributed = attribute_sung_frames(sung_curve, note, is_last_note=True)
    assert [f["t"] for f in attributed] == [2.2]


def test_attribute_sung_frames_last_note_excludes_beyond_tolerance():
    note = {"index": 0, "start_t": 1.0, "end_t": 2.0, "hz": 440.0, "midi_note": 69}
    sung_curve = [{"t": 2.5, "aligned_t": 2.5}]  # 0.5s past end, beyond 0.3s tolerance
    attributed = attribute_sung_frames(sung_curve, note, is_last_note=True)
    assert [f["t"] for f in attributed] == []


def _sung_frame(t: float, hz: float | None, voiced: bool = True, aligned_t: float | None = None) -> dict:
    return {
        "t": t,
        "hz": hz,
        "voiced": voiced,
        "confidence": 0.9,
        "aligned_t": aligned_t if aligned_t is not None else t,
    }


def test_classify_cents_boundaries():
    assert classify_cents(14.9) == "green"
    assert classify_cents(15.0) == "green"
    assert classify_cents(15.1) == "yellow"
    assert classify_cents(-49.9) == "yellow"
    assert classify_cents(50.0) == "yellow"
    assert classify_cents(50.1) == "red"


def test_compute_cents_deviation_uses_median_not_mean():
    note = {"start_t": 0.0, "end_t": 1.2, "hz": 440.0}
    frames = [_sung_frame(round(i * 0.01, 3), 440.0) for i in range(90)]
    # Letzte 30 Frames (Phrasenende) driften stark ab - Median soll das ignorieren.
    frames += [
        _sung_frame(round((90 + i) * 0.01, 3), 440.0 * 2 ** (-100 * (i / 30) / 1200))
        for i in range(30)
    ]
    result = compute_cents_deviation(note, frames)
    assert result is not None
    assert abs(result["value"]) < 5


def test_compute_cents_deviation_none_without_voiced_frames():
    note = {"start_t": 0.0, "end_t": 1.0, "hz": 440.0}
    frames = [_sung_frame(0.5, None, voiced=False)]
    assert compute_cents_deviation(note, frames) is None


def test_compute_coverage_fraction_full_coverage():
    note = {"start_t": 0.0, "end_t": 1.0}
    frames = [_sung_frame(round(i * 0.01, 3), 440.0) for i in range(100)]
    assert compute_coverage_fraction(note, frames) == pytest.approx(1.0, abs=0.02)


def test_compute_coverage_fraction_no_voiced_frames():
    note = {"start_t": 0.0, "end_t": 1.0}
    assert compute_coverage_fraction(note, []) == 0.0


def test_is_missed_flags_low_coverage():
    assert is_missed(coverage_fraction=0.3, cents_value=0.0) is True
    assert is_missed(coverage_fraction=0.8, cents_value=0.0) is False


def test_is_missed_flags_gross_pitch_error():
    assert is_missed(coverage_fraction=1.0, cents_value=500.0) is True
    assert is_missed(coverage_fraction=1.0, cents_value=100.0) is False


def test_classify_timing_boundaries():
    assert classify_timing(60.0) == "on_time"
    assert classify_timing(60.1) == "too_early"
    assert classify_timing(-60.0) == "on_time"
    assert classify_timing(-60.1) == "too_late"


def test_compute_onset_deviation_ms_recovers_offset():
    # Zielnote beginnt bei t=2.0s; die "gesungene" Onset-Umgebung liegt bei
    # aligned_t~2.0, aber raw t~1.85 (150ms zu frueh gesungen) - deviation_ms
    # muss ~+150ms betragen (aligned_t - t).
    note = {"start_t": 2.0, "end_t": 3.0}
    sung_curve = [
        {"t": round(1.85 + i * 0.01, 3), "hz": 391.995, "voiced": True,
         "aligned_t": round(2.0 + i * 0.01, 3)}
        for i in range(10)
    ]
    deviation = compute_onset_deviation_ms(sung_curve, note)
    assert deviation is not None
    assert 100 <= deviation <= 200


def test_compute_onset_deviation_ms_none_without_voiced_frames():
    note = {"start_t": 2.0, "end_t": 3.0}
    assert compute_onset_deviation_ms([], note) is None


from backend.scoring.stability import compute_phrase_end_drift, compute_stability, is_held_note


def test_is_held_note():
    assert is_held_note({"start_t": 0.0, "end_t": 0.6}) is True
    assert is_held_note({"start_t": 0.0, "end_t": 0.59}) is False


def test_compute_stability_not_applicable_for_short_note():
    note = {"start_t": 0.0, "end_t": 0.3, "hz": 440.0}
    result = compute_stability(note, [])
    assert result["applicable"] is False


def test_compute_phrase_end_drift_flags_tail_drop():
    note = {"start_t": 3.0, "end_t": 4.2, "hz": 329.628}
    frames = [
        _sung_frame(round(3.0 + i * 0.01, 3), 329.628, aligned_t=round(3.0 + i * 0.01, 3))
        for i in range(90)
    ]
    frames += [
        _sung_frame(
            round(3.9 + i * 0.01, 3),
            329.628 * 2 ** (-100 * (i / 30) / 1200),
            aligned_t=round(3.9 + i * 0.01, 3),
        )
        for i in range(30)
    ]
    result = compute_phrase_end_drift(note, frames)
    assert result["applicable"] is True
    assert result["flag"] is True
    assert result["direction"] == "down"


def test_compute_stability_and_drift_ignore_constant_offset():
    # Konstante -40 Cent ueber die ganze Note - kein Drift (Hauptteil und Ende
    # sind gleich weit daneben), auch keine Instabilitaet (Streuung im Hauptteil
    # bleibt klein).
    note = {"start_t": 1.0, "end_t": 2.0, "hz": 329.628}
    offset_hz = 329.628 * 2 ** (-40 / 1200)
    frames = [
        _sung_frame(round(1.0 + i * 0.01, 3), offset_hz, aligned_t=round(1.0 + i * 0.01, 3))
        for i in range(100)
    ]
    stability = compute_stability(note, frames)
    drift = compute_phrase_end_drift(note, frames)
    assert stability["flag"] is False
    assert drift["flag"] is False


def test_compute_stability_excludes_tail_even_when_tail_dominates_frame_count():
    # Kurze gehaltene Note (0.62s): Hauptteil nur 27 Frames, Tail 30 Frames - der
    # Tail waere zahlenmaessig in der Mehrheit, wenn er faelschlich mit einbezogen
    # wuerde. Body ist sauber (0 Cent), Tail wackelt stark (+-300 Cent) - eine
    # nicht-disjunkte Implementierung (die den Hauptteil bis end_t statt bis
    # end_t - DRIFT_TAIL_SECONDS berechnet) wuerde hier MAD weit ueber die
    # Schwelle treiben; die korrekte, disjunkte Implementierung nicht.
    note = {"start_t": 0.0, "end_t": 0.62, "hz": 440.0}
    body_frames = [
        _sung_frame(round(0.05 + i * 0.01, 3), 440.0, aligned_t=round(0.05 + i * 0.01, 3))
        for i in range(27)
    ]
    tail_frames = []
    for i in range(30):
        cents = 300.0 if i % 2 == 0 else -300.0
        hz = 440.0 * 2 ** (cents / 1200.0)
        tail_frames.append(
            _sung_frame(round(0.32 + i * 0.01, 3), hz, aligned_t=round(0.32 + i * 0.01, 3))
        )
    frames = body_frames + tail_frames

    stability = compute_stability(note, frames)
    assert stability["applicable"] is True
    assert stability["flag"] is False
    assert stability["mad_cents"] < 5.0


from backend.scoring import score_performance


def test_score_performance_raises_without_aligned_t():
    target_curve = [{"t": 0.0, "hz": 440.0, "midi_note": 69}]
    sung_curve = [{"t": 0.0, "hz": 440.0, "voiced": True, "confidence": 0.9}]  # kein aligned_t
    with pytest.raises(ValueError):
        score_performance(target_curve, sung_curve)


def test_score_performance_empty_curves_returns_empty_result():
    result = score_performance([], [])
    assert result["notes"] == []
    assert result["summary"]["note_count"] == 0
    assert result["summary"]["problem_tags"] == []


def test_score_performance_single_correct_note():
    target_curve = _flat_curve(440.0, 100)
    sung_curve = [
        {"t": round(i * 0.01, 3), "hz": 440.0, "voiced": True, "confidence": 0.9,
         "aligned_t": round(i * 0.01, 3)}
        for i in range(100)
    ]
    result = score_performance(target_curve, sung_curve)
    assert len(result["notes"]) == 1
    note = result["notes"][0]
    assert note["missed"] is False
    assert note["cents_deviation"]["classification"] == "green"
    assert note["timing"]["classification"] == "on_time"
    assert result["summary"]["cents_green"] == 1
    assert result["summary"]["problem_tags"] == []

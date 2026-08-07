"""Tests fuer die Bewertungs-Engine (Phase 4, Kernpaket)."""

from __future__ import annotations

import pytest

from backend.config import MISSED_NOTE_MIN_COVERAGE_FRACTION
from backend.scoring.notes import attribute_sung_frames, hz_to_cents, hz_to_midi_note, segment_target_notes
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


def test_compute_coverage_fraction_ignores_tail_content_past_note_end():
    # Note ist komplett still (0.0-0.3s), aber danach (ab 0.3s, im LAST_NOTE_TAIL_
    # TOLERANCE_SECONDS-Fenster einer letzten Note) wird woanders weitergesungen -
    # das darf nicht als (nahezu) volle Abdeckung dieser Note durchgehen. Ohne den
    # Bucket-Clamp waeren hier 20 verschiedene Buckets (30..49) betroffen und die
    # Abdeckung wuerde auf min(1.0, 20/30) ~= 0.67 aufgeblaeht ("volle Abdeckung
    # vortaeuschen"). Mit dem Clamp faellt jeder dieser Frames auf denselben letzten
    # gueltigen Bucket (29, durch Floating-Point-Rundung von 0.3/0.01) zurueck, was
    # die Abdeckung auf maximal einen einzelnen Bucket (1/30 ~= 0.03) begrenzt - weit
    # unter der is_missed()-Mindestabdeckung von 0.5, die Note bleibt also korrekt
    # als verfehlt erkannt (die urspruengliche, ungeklammerte Version haette hier
    # faelschlich coverage_fraction > MISSED_NOTE_MIN_COVERAGE_FRACTION liefern koennen).
    note = {"start_t": 0.0, "end_t": 0.3}
    frames = [_sung_frame(round(0.3 + i * 0.01, 3), 440.0, aligned_t=round(0.3 + i * 0.01, 3)) for i in range(20)]
    coverage = compute_coverage_fraction(note, frames)
    assert coverage < MISSED_NOTE_MIN_COVERAGE_FRACTION
    assert is_missed(coverage, cents_value=None) is True


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


def test_compute_stability_flags_genuine_instability():
    # Gehaltene Note (0.9s), Hauptteil wackelt staendig zwischen +/-40 Cent (echte
    # Instabilitaet, kein monotoner Drift) - muss stability.flag = True ergeben.
    note = {"start_t": 0.0, "end_t": 0.9, "hz": 440.0}
    frames = []
    for i in range(50):
        cents = 40.0 if i % 2 == 0 else -40.0
        hz = 440.0 * 2 ** (cents / 1200.0)
        frames.append(_sung_frame(round(0.05 + i * 0.01, 3), hz, aligned_t=round(0.05 + i * 0.01, 3)))
    result = compute_stability(note, frames)
    assert result["applicable"] is True
    assert result["flag"] is True


from backend.scoring.glides import compute_glide


def test_compute_glide_flags_genuine_glide_and_reports_direction():
    # Note 1.0-2.0s, Zielton 440Hz. Kopf-Fenster (1.00-1.15s): 15 Frames bei -80 Cent
    # (deutlich abseits). Rest (1.15-1.99s): 85 Frames exakt auf dem Zielton (sauber
    # gelandet) - klassischer Glide-von-unten.
    note = {"start_t": 1.0, "end_t": 2.0, "hz": 440.0}
    off_pitch_hz = 440.0 * 2 ** (-80 / 1200)
    head_frames = [
        _sung_frame(round(1.0 + i * 0.01, 3), off_pitch_hz, aligned_t=round(1.0 + i * 0.01, 3))
        for i in range(15)
    ]
    rest_frames = [
        _sung_frame(round(1.15 + i * 0.01, 3), 440.0, aligned_t=round(1.15 + i * 0.01, 3))
        for i in range(85)
    ]
    result = compute_glide(note, head_frames + rest_frames)
    assert result["applicable"] is True
    assert result["flag"] is True
    assert result["direction"] == "up"
    assert result["onset_cents_deviation"] == pytest.approx(-80.0, abs=0.1)


def test_compute_glide_does_not_flag_clean_onset():
    # Note 1.0-2.0s, Zielton 440Hz, durchgehend auf dem Zielton - kein Glide.
    note = {"start_t": 1.0, "end_t": 2.0, "hz": 440.0}
    frames = [
        _sung_frame(round(1.0 + i * 0.01, 3), 440.0, aligned_t=round(1.0 + i * 0.01, 3))
        for i in range(100)
    ]
    result = compute_glide(note, frames)
    assert result["applicable"] is True
    assert result["flag"] is False
    assert result["direction"] is None


def test_compute_glide_not_applicable_with_too_few_head_frames():
    # Nur 2 Frames im Kopf-Fenster (< GLIDE_MIN_HEAD_FRAMES=3), obwohl der Rest der
    # Note reichlich Frames hat.
    note = {"start_t": 1.0, "end_t": 2.0, "hz": 440.0}
    off_pitch_hz = 440.0 * 2 ** (-80 / 1200)
    head_frames = [
        _sung_frame(round(1.0 + i * 0.01, 3), off_pitch_hz, aligned_t=round(1.0 + i * 0.01, 3))
        for i in range(2)
    ]
    rest_frames = [
        _sung_frame(round(1.15 + i * 0.01, 3), 440.0, aligned_t=round(1.15 + i * 0.01, 3))
        for i in range(85)
    ]
    result = compute_glide(note, head_frames + rest_frames)
    assert result["applicable"] is False
    assert result["onset_cents_deviation"] is None
    assert result["flag"] is False


def test_compute_glide_not_applicable_when_note_shorter_than_head_window():
    # Note ist nur 0.1s lang (< GLIDE_HEAD_SECONDS=0.15s) - das ganze Notenfenster
    # wird zum Kopf-Fenster, es gibt kein Rest-Fenster zum Vergleichen.
    note = {"start_t": 0.0, "end_t": 0.1, "hz": 440.0}
    off_pitch_hz = 440.0 * 2 ** (-80 / 1200)
    frames = [
        _sung_frame(round(i * 0.01, 3), off_pitch_hz, aligned_t=round(i * 0.01, 3))
        for i in range(8)
    ]
    result = compute_glide(note, frames)
    assert result["applicable"] is False


def test_hz_to_midi_note_reference_a4():
    assert hz_to_midi_note(440.0) == 69


def test_hz_to_midi_note_middle_c():
    assert hz_to_midi_note(261.626) == 60


from backend.scoring.vocal_range import compute_vocal_range


def test_compute_vocal_range_trims_outliers_via_percentile():
    # 100 Frames gleichmaessig zwischen ~220Hz und ~438Hz verteilt, plus 2 extreme
    # Ausreisser (55Hz und 1760Hz, je 2 Oktaven ausserhalb) - die Perzentil-Trimmung
    # (5./95.) darf sie nicht in min_hz/max_hz einfliessen lassen.
    frames = [_sung_frame(round(i * 0.01, 3), 220.0 + i * 2.2, aligned_t=round(i * 0.01, 3)) for i in range(100)]
    frames.append(_sung_frame(1.0, 55.0, aligned_t=1.0))
    frames.append(_sung_frame(1.01, 1760.0, aligned_t=1.01))
    result = compute_vocal_range(frames)
    assert result["applicable"] is True
    assert 200.0 < result["min_hz"] < 240.0
    assert 420.0 < result["max_hz"] < 445.0


def test_compute_vocal_range_not_applicable_with_too_few_frames():
    frames = [_sung_frame(round(i * 0.01, 3), 440.0, aligned_t=round(i * 0.01, 3)) for i in range(5)]
    result = compute_vocal_range(frames)
    assert result["applicable"] is False
    assert result["min_hz"] is None
    assert result["max_hz"] is None
    assert result["min_midi_note"] is None
    assert result["max_midi_note"] is None


def test_compute_vocal_range_not_applicable_when_fully_unvoiced():
    frames = [
        _sung_frame(round(i * 0.01, 3), None, voiced=False, aligned_t=round(i * 0.01, 3))
        for i in range(50)
    ]
    result = compute_vocal_range(frames)
    assert result["applicable"] is False


def test_compute_vocal_range_uniform_pitch_min_equals_max():
    frames = [_sung_frame(round(i * 0.01, 3), 440.0, aligned_t=round(i * 0.01, 3)) for i in range(50)]
    result = compute_vocal_range(frames)
    assert result["applicable"] is True
    assert result["min_hz"] == pytest.approx(440.0)
    assert result["max_hz"] == pytest.approx(440.0)
    assert result["min_midi_note"] == 69
    assert result["max_midi_note"] == 69


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


def test_score_performance_does_not_timing_flag_a_missed_note():
    target_curve = _flat_curve(440.0, 100)  # eine Note, 1.0s, C4-artig
    # Komplett stille "Gesangs"-Kurve fuer denselben Zeitraum, aber woanders (bei
    # t=5.0s) taucht zufaellig ein stimmhafter Frame auf, der frueher versehentlich
    # als "Timing-Treffer" fuer diese Note herangezogen worden waere.
    sung_curve = [
        {"t": round(i * 0.01, 3), "hz": None, "voiced": False, "confidence": 0.0,
         "aligned_t": round(i * 0.01, 3)}
        for i in range(100)
    ] + [
        {"t": 5.0, "hz": 440.0, "voiced": True, "confidence": 0.9, "aligned_t": 5.0},
    ]
    result = score_performance(target_curve, sung_curve)
    note = result["notes"][0]
    assert note["missed"] is True
    assert note["timing"]["classification"] == "on_time"
    assert result["summary"]["timing_flagged_count"] == 0
    assert "timingprobleme" not in result["summary"]["problem_tags"]


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


def test_score_performance_includes_sung_t_from_first_attributed_frame():
    target_curve = _flat_curve(440.0, 100)  # eine Note, 0.0s-1.0s
    # Raw t is offset by 5.0s from aligned_t to distinguish the two fields.
    # aligned_t falls in the note's [0.0, 1.0) window so frames are attributed;
    # sung_t must read raw t (not aligned_t) to catch field-mixup bugs.
    sung_curve = [
        {"t": round(i * 0.01 + 5.0, 3), "hz": 440.0, "voiced": True, "confidence": 0.9,
         "aligned_t": round(i * 0.01, 3)}
        for i in range(50)
    ]
    score = score_performance(target_curve, sung_curve)
    assert score["notes"][0]["sung_t"] == pytest.approx(5.0)


def test_score_performance_sung_t_is_none_when_note_has_no_attributed_frames():
    target_curve = _flat_curve(440.0, 100)
    score = score_performance(target_curve, [])
    assert score["notes"][0]["sung_t"] is None


def test_score_performance_flags_glide_and_adds_problem_tag():
    # Zielnote 1.0s bei 440Hz. Gesang deckt die ganze Note ab: Kopf (0.00-0.15s)
    # deutlich abseits (-80 Cent), Rest (0.15-0.99s) exakt auf dem Zielton -
    # ein klarer, hoerbarer Glide, der insgesamt sauber gelandet ist.
    target_curve = [{"t": round(i * 0.01, 3), "hz": 440.0, "midi_note": 69} for i in range(100)]
    off_pitch_hz = 440.0 * 2 ** (-80 / 1200)
    sung_curve = [
        _sung_frame(round(i * 0.01, 3), off_pitch_hz, aligned_t=round(i * 0.01, 3))
        for i in range(15)
    ] + [
        _sung_frame(round(i * 0.01, 3), 440.0, aligned_t=round(i * 0.01, 3))
        for i in range(15, 99)
    ]
    result = score_performance(target_curve, sung_curve, frame_rate_hz=100.0)
    note = result["notes"][0]
    assert note["missed"] is False
    assert note["glide"]["applicable"] is True
    assert note["glide"]["flag"] is True
    assert note["glide"]["direction"] == "up"
    assert result["summary"]["glide_flagged_count"] == 1
    assert "haeufiges_hineingleiten" in result["summary"]["problem_tags"]


def test_score_performance_skips_glide_for_missed_notes():
    # Zielnote 1.0s. Gesang deckt nur die ersten 0.30s ab (Coverage 30% < 50% ->
    # verfehlt), obwohl die vorhandenen Frames rein rechnerisch wie ein Glide
    # aussehen wuerden (Kopf abseits, kurzer Rest sauber). Das Gating in score.py
    # darf compute_glide() bei einer verfehlten Note gar nicht erst aufrufen.
    target_curve = [{"t": round(i * 0.01, 3), "hz": 440.0, "midi_note": 69} for i in range(100)]
    off_pitch_hz = 440.0 * 2 ** (-80 / 1200)
    sung_curve = [
        _sung_frame(round(i * 0.01, 3), off_pitch_hz, aligned_t=round(i * 0.01, 3))
        for i in range(15)
    ] + [
        _sung_frame(round(i * 0.01, 3), 440.0, aligned_t=round(i * 0.01, 3))
        for i in range(15, 30)
    ]
    result = score_performance(target_curve, sung_curve, frame_rate_hz=100.0)
    note = result["notes"][0]
    assert note["missed"] is True
    assert note["glide"] == {
        "applicable": False, "onset_cents_deviation": None, "flag": False, "direction": None,
    }
    assert result["summary"]["glide_flagged_count"] == 0
    assert "haeufiges_hineingleiten" not in result["summary"]["problem_tags"]


def test_score_performance_skips_glide_for_timing_flagged_notes():
    # Gleiche Kopf/Rest-Frame-Konstruktion wie
    # test_score_performance_flags_glide_and_adds_problem_tag (Kopf abseits, Rest
    # sauber - rein rechnerisch ein klarer Glide), aber die rohe Aufnahmezeit t liegt
    # durchgehend 100ms vor aligned_t, was
    # einen "too_early"-Timing-Befund erzeugt (> TIMING_OK_THRESHOLD_MS=60ms). Das
    # Gating in score.py darf compute_glide() bei einer timing-geflaggten Note nicht
    # aufrufen, obwohl die Note weder verfehlt noch cents-rot ist.
    target_curve = [{"t": round(i * 0.01, 3), "hz": 440.0, "midi_note": 69} for i in range(100)]
    off_pitch_hz = 440.0 * 2 ** (-80 / 1200)
    sung_curve = [
        _sung_frame(round(i * 0.01 - 0.1, 3), off_pitch_hz, aligned_t=round(i * 0.01, 3))
        for i in range(15)
    ] + [
        _sung_frame(round(i * 0.01 - 0.1, 3), 440.0, aligned_t=round(i * 0.01, 3))
        for i in range(15, 99)
    ]
    result = score_performance(target_curve, sung_curve, frame_rate_hz=100.0)
    note = result["notes"][0]
    assert note["missed"] is False
    assert note["cents_deviation"]["classification"] in ("green", "yellow")
    assert note["timing"]["classification"] == "too_early"
    assert note["glide"] == {
        "applicable": False, "onset_cents_deviation": None, "flag": False, "direction": None,
    }
    assert result["summary"]["glide_flagged_count"] == 0
    assert "haeufiges_hineingleiten" not in result["summary"]["problem_tags"]

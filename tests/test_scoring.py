"""Tests fuer die Bewertungs-Engine (Phase 4, Kernpaket)."""

from __future__ import annotations

import pytest

from backend.scoring.notes import attribute_sung_frames, hz_to_cents, segment_target_notes


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


def test_attribute_sung_frames_last_note_is_open_ended():
    note = {"index": 0, "start_t": 1.0, "end_t": 2.0, "hz": 440.0, "midi_note": 69}
    sung_curve = [{"t": 2.5, "aligned_t": 2.5}]
    attributed = attribute_sung_frames(sung_curve, note, is_last_note=True)
    assert [f["t"] for f in attributed] == [2.5]

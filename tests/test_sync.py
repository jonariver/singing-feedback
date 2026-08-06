"""Tests fuer die DTW-Ausrichtung (Phase 3): Onset-Huellkurven + align_curves."""

from __future__ import annotations

import numpy as np
import pretty_midi
import pytest

from backend.sync import (
    align_curves,
    onset_envelope_from_midi_track,
    onset_envelope_from_signal,
)
from backend.midi_analysis import track_pitch_curve


def _two_note_pm() -> pretty_midi.PrettyMIDI:
    pm = pretty_midi.PrettyMIDI()
    inst = pretty_midi.Instrument(program=53, name="Vocal")
    inst.notes.append(pretty_midi.Note(velocity=90, pitch=60, start=0.0, end=1.0))
    inst.notes.append(pretty_midi.Note(velocity=90, pitch=64, start=1.0, end=2.0))
    pm.instruments.append(inst)
    return pm


def test_onset_envelope_from_midi_track_matches_curve_length():
    pm = _two_note_pm()
    curve = track_pitch_curve(pm, track_index=0, frame_rate_hz=100.0)
    env = onset_envelope_from_midi_track(pm, track_index=0, frame_rate_hz=100.0)
    assert len(env) == len(curve)


def test_onset_envelope_from_midi_track_peaks_at_note_onsets():
    env = onset_envelope_from_midi_track(
        _two_note_pm(), track_index=0, frame_rate_hz=100.0, decay_seconds=0.06,
    )
    # decay_frames = round(0.06 * 100) = 6 -> Kernel deckt Frames [onset, onset+6) ab.
    assert env[0] == pytest.approx(1.0)     # Onset Note 0 bei t=0.0s (Frame 0)
    assert env[100] == pytest.approx(1.0)   # Onset Note 1 bei t=1.0s (Frame 100)
    assert env[6] == pytest.approx(0.0)     # ausserhalb der Decay-Spanne von Note 0
    assert env[50] == pytest.approx(0.0)    # weit vor dem zweiten Onset


def test_onset_envelope_from_signal_is_nonnegative_and_has_plausible_length():
    sr = 22050
    duration = 1.0
    t = np.arange(int(duration * sr)) / sr
    y = (0.3 * np.sin(2 * np.pi * 440.0 * t)).astype(np.float32)

    env = onset_envelope_from_signal(y, sr, frame_rate_hz=100.0)

    assert len(env) > 90  # ~100 Frames fuer 1s bei 100Hz, kleine Abweichung durch librosa-Padding ok
    assert all(v >= 0 for v in env)


def test_onset_envelope_from_midi_track_onset_near_track_end_not_dropped():
    """Regression test: ensure onsets near track end are not silently dropped due to rounding.

    Verifies that onset_frame uses consistent floor semantics with n_frames calculation,
    so that notes ending close to track's end_time have their onsets preserved.
    """
    # Create a MIDI with a note starting near the end: start=1.006, end=1.007
    # At frame_rate_hz=100, step=0.01:
    # - n_frames = int(1.007/0.01)+1 = int(100.7)+1 = 101
    # - onset_frame = int(1.006/0.01) = int(100.6) = 100 (floor, not round)
    # With round() (wrong), onset_frame = 101, which >= n_frames would be skipped.
    pm = pretty_midi.PrettyMIDI()
    inst = pretty_midi.Instrument(program=53, name="Vocal")
    inst.notes.append(pretty_midi.Note(velocity=90, pitch=60, start=1.006, end=1.007))
    pm.instruments.append(inst)

    env = onset_envelope_from_midi_track(pm, track_index=0, frame_rate_hz=100.0, decay_seconds=0.06)

    # Verify the note's onset frame (100 = int(1.006/0.01)) has a peak value >= decay kernel's maximum
    # The decay kernel starts at exp(-3.0*0/6) = exp(0) = 1.0
    assert env[100] == pytest.approx(1.0), "Onset at frame 100 should peak at 1.0, not be silently dropped"


def test_align_curves_recovers_early_onset_offset():
    step = 0.01  # 100Hz
    n = 200
    target_curve = [{"t": round(i * step, 3), "hz": 440.0, "midi_note": 69} for i in range(n)]
    target_envelope = [0.0] * n
    target_envelope[50] = 1.0  # Zielereignis bei t=0.50s

    sung_curve = [
        {"t": round(i * step, 3), "hz": 440.0, "voiced": True, "confidence": 0.9}
        for i in range(n)
    ]
    sung_envelope = [0.0] * n
    sung_envelope[35] = 1.0  # dasselbe Ereignis, aber 150ms (15 Frames) zu frueh (t=0.35s)

    result = align_curves(target_curve, target_envelope, sung_curve, sung_envelope)

    assert result["target_duration"] == target_curve[-1]["t"]
    aligned_t = result["sung_curve"][35]["aligned_t"]
    assert aligned_t is not None
    assert abs(aligned_t - 0.50) < 0.03


def test_align_curves_handles_empty_input_without_raising():
    result = align_curves([], [], [], [])
    assert result == {"sung_curve": [], "target_duration": 0.0}

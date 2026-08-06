"""Tests fuer die DTW-Ausrichtung (Phase 3): Onset-Huellkurven + align_curves."""

from __future__ import annotations

import numpy as np
import pretty_midi
import pytest

from backend.sync import (
    # align_curves,  # TODO: uncomment in Task 3 when align_curves is implemented
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

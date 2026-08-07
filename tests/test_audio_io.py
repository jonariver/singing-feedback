"""Tests fuer backend/audio_io.py."""

from __future__ import annotations

import io

import numpy as np
import pytest
import soundfile as sf

from backend.audio_io import AudioDecodeError, load_audio_signal

SR = 22050


def _wav_bytes(signal: np.ndarray, sr: int = SR) -> bytes:
    buf = io.BytesIO()
    sf.write(buf, signal, sr, format="WAV")
    return buf.getvalue()


def test_load_audio_signal_reports_original_duration_when_not_truncated():
    duration = 1.0
    signal = np.zeros(int(duration * SR))
    y, sr, original_duration_seconds = load_audio_signal(_wav_bytes(signal), max_seconds=90.0)
    assert original_duration_seconds == pytest.approx(1.0, abs=0.01)
    assert y.shape[0] / sr == pytest.approx(1.0, abs=0.01)  # nicht gekuerzt


def test_load_audio_signal_reports_pre_truncation_duration_when_truncated():
    duration = 3.0
    signal = np.zeros(int(duration * SR))
    y, sr, original_duration_seconds = load_audio_signal(_wav_bytes(signal), max_seconds=1.0)
    assert original_duration_seconds == pytest.approx(3.0, abs=0.01)
    assert y.shape[0] / sr == pytest.approx(1.0, abs=0.01)  # tatsaechlich gekuerzt auf 1.0s


def test_load_audio_signal_rejects_empty_bytes():
    with pytest.raises(AudioDecodeError):
        load_audio_signal(b"")

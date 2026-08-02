import io

import numpy as np
import pytest
import soundfile as sf

from backend.pitch_detection import PitchAnalysisError, analyze_pitch

SR = 22050


def _wav_bytes(signal: np.ndarray, sr: int = SR) -> bytes:
    buf = io.BytesIO()
    sf.write(buf, signal, sr, format="WAV")
    return buf.getvalue()


def test_analyze_pitch_detects_known_sine_frequency():
    duration = 1.0
    freq = 440.0
    t = np.arange(int(duration * SR)) / SR
    signal = 0.3 * np.sin(2 * np.pi * freq * t)

    curve = analyze_pitch(_wav_bytes(signal), filename_hint="a4.wav", fmin=65.0, fmax=1050.0)

    voiced_hz = [p["hz"] for p in curve if p["voiced"]]
    assert len(voiced_hz) > len(curve) * 0.5  # ueberwiegend als stimmhaft erkannt

    # Im Mittel nah an 440 Hz (Toleranz grosszuegig wegen pYIN-Randeffekten).
    mean_hz = sum(voiced_hz) / len(voiced_hz)
    assert abs(mean_hz - freq) < 5.0


def test_analyze_pitch_marks_silence_as_unvoiced():
    silence = np.zeros(int(1.0 * SR))
    curve = analyze_pitch(_wav_bytes(silence))
    assert all(not p["voiced"] for p in curve)
    assert all(p["hz"] is None for p in curve)


def test_analyze_pitch_rejects_empty_input():
    with pytest.raises(PitchAnalysisError):
        analyze_pitch(b"")


def test_analyze_pitch_truncates_to_max_seconds():
    duration = 3.0
    freq = 440.0
    t = np.arange(int(duration * SR)) / SR
    signal = 0.3 * np.sin(2 * np.pi * freq * t)

    curve = analyze_pitch(_wav_bytes(signal), max_seconds=1.0)
    assert curve[-1]["t"] <= 1.05

import io

import av
import numpy as np
import pytest
import soundfile as sf

from backend.pitch_detection import PitchAnalysisError, analyze_pitch

SR = 22050


def _wav_bytes(signal: np.ndarray, sr: int = SR) -> bytes:
    buf = io.BytesIO()
    sf.write(buf, signal, sr, format="WAV")
    return buf.getvalue()


def _m4a_bytes(signal: np.ndarray, sr: int = SR) -> bytes:
    """Kodiert ein Sinussignal als AAC-in-M4A, wie es z.B. der 'record'-Flutter-Package
    auf Android/iOS produziert - genau das Format, das soundfile/audioread ohne
    System-ffmpeg nicht dekodieren koennen (siehe _load_with_pyav-Fallback)."""
    buf = io.BytesIO()
    container = av.open(buf, mode="w", format="mp4")
    stream = container.add_stream("aac", rate=sr)
    frame = av.AudioFrame.from_ndarray(
        signal.astype(np.float32).reshape(1, -1), format="fltp", layout="mono"
    )
    frame.sample_rate = sr
    for packet in stream.encode(frame):
        container.mux(packet)
    for packet in stream.encode(None):
        container.mux(packet)
    container.close()
    return buf.getvalue()


def test_analyze_pitch_detects_known_sine_frequency():
    duration = 1.0
    freq = 440.0
    t = np.arange(int(duration * SR)) / SR
    signal = 0.3 * np.sin(2 * np.pi * freq * t)

    curve = analyze_pitch(_wav_bytes(signal), filename_hint="a4.wav", fmin=65.0, fmax=1050.0)["curve"]

    voiced_hz = [p["hz"] for p in curve if p["voiced"]]
    assert len(voiced_hz) > len(curve) * 0.5  # ueberwiegend als stimmhaft erkannt

    # Im Mittel nah an 440 Hz (Toleranz grosszuegig wegen pYIN-Randeffekten).
    mean_hz = sum(voiced_hz) / len(voiced_hz)
    assert abs(mean_hz - freq) < 5.0


def test_analyze_pitch_marks_silence_as_unvoiced():
    silence = np.zeros(int(1.0 * SR))
    curve = analyze_pitch(_wav_bytes(silence))["curve"]
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

    result = analyze_pitch(_wav_bytes(signal), max_seconds=1.0)
    assert result["curve"][-1]["t"] <= 1.05
    assert result["truncated"] is True
    assert result["original_duration_seconds"] == pytest.approx(3.0, abs=0.1)


def test_analyze_pitch_not_truncated_when_within_max_seconds():
    duration = 1.0
    freq = 440.0
    t = np.arange(int(duration * SR)) / SR
    signal = 0.3 * np.sin(2 * np.pi * freq * t)

    result = analyze_pitch(_wav_bytes(signal), max_seconds=90.0)
    assert result["truncated"] is False
    assert result["original_duration_seconds"] == pytest.approx(1.0, abs=0.05)


def test_analyze_pitch_decodes_m4a_via_pyav_fallback():
    """M4A/AAC (z.B. vom 'record'-Package auf Android/iOS) kann soundfile nicht lesen
    und audioreads Fallback braucht einen System-ffmpeg-Binary, den es hier nicht gibt -
    das muss stattdessen ueber den PyAV-Fallback in pyin.py laufen."""
    duration = 1.0
    freq = 440.0
    t = np.arange(int(duration * SR)) / SR
    signal = 0.3 * np.sin(2 * np.pi * freq * t)

    curve = analyze_pitch(
        _m4a_bytes(signal), filename_hint="aufnahme.m4a", fmin=65.0, fmax=1050.0
    )["curve"]

    voiced_hz = [p["hz"] for p in curve if p["voiced"]]
    assert len(voiced_hz) > len(curve) * 0.5
    mean_hz = sum(voiced_hz) / len(voiced_hz)
    assert abs(mean_hz - freq) < 5.0

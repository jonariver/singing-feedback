import io
from pathlib import Path

import numpy as np
import pretty_midi
import pytest
import soundfile as sf

from backend.config import TRACK_PREVIEW_SAMPLE_RATE
from backend.midi_analysis import load_midi, synthesize_track_preview

from .fixtures.generate_fixtures import generate

FIXTURES_DIR = Path(__file__).resolve().parent / "fixtures"


def _load_reference():
    midi_path, _ = generate(FIXTURES_DIR)
    return load_midi(midi_path.read_bytes())


def test_preview_is_valid_decodable_wav():
    pm = _load_reference()
    wav_bytes = synthesize_track_preview(pm, track_index=0)
    audio, sr = sf.read(io.BytesIO(wav_bytes))
    assert sr == TRACK_PREVIEW_SAMPLE_RATE
    assert len(audio) > 0


def test_preview_duration_is_capped_at_max_seconds():
    pm = _load_reference()  # test_reference.mid Melodie ist 5.0s lang (siehe MELODY)
    wav_bytes = synthesize_track_preview(pm, track_index=0, max_seconds=2.0)
    audio, sr = sf.read(io.BytesIO(wav_bytes))
    duration = len(audio) / sr
    assert duration <= 2.01  # kleine Toleranz fuer Rundung auf ganze Samples


def test_preview_of_empty_track_is_silence_not_error():
    pm = pretty_midi.PrettyMIDI()
    inst = pretty_midi.Instrument(program=0, name="Empty")
    pm.instruments.append(inst)

    wav_bytes = synthesize_track_preview(pm, track_index=0, max_seconds=1.0)
    audio, sr = sf.read(io.BytesIO(wav_bytes))
    assert np.allclose(audio, 0.0)


def test_preview_applies_transposition():
    pm = _load_reference()
    wav_low = synthesize_track_preview(pm, track_index=0, max_seconds=1.0)
    wav_high = synthesize_track_preview(pm, track_index=0, transpose_semitones=12, max_seconds=1.0)
    assert wav_low != wav_high


def test_preview_invalid_track_index_raises_value_error():
    pm = _load_reference()
    with pytest.raises(ValueError):
        synthesize_track_preview(pm, track_index=99)

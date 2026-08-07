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


def test_preview_clamps_overlapping_notes_to_valid_range(monkeypatch):
    # Eine einzelne Note erreicht isoliert einen Peak von ca. 0.159 (nicht die
    # theoretische Obergrenze 0.2, da die Obertoene nicht bei jedem Sample perfekt
    # phasengleich sind - siehe _note_segment). 8 deckungsgleiche Noten (gleiche
    # Tonhoehe/Start/Ende) summieren sich konstruktiv auf ueber 1.0 (~1.27 vor einem
    # Clamp) - provably ueber Vollaussteuerung ohne Clamp.
    #
    # sf.write saettigt out-of-range float-Samples beim PCM_16-Default-Subtype selbst
    # bereits sicher auf [-1, 1] (kein Crash, kein Wrap-Around - empirisch verifiziert),
    # wodurch ein reiner Check der dekodierten Samples den fehlenden Clamp in
    # synthesize_track_preview nicht aufdecken wuerde (er waere immer <= 1.0, mit oder
    # ohne Fix). Daher spionieren wir zusaetzlich das an sf.write uebergebene Array aus,
    # um den eigentlichen Clamp in synthesize_track_preview zu verifizieren.
    captured: dict[str, np.ndarray] = {}
    original_write = sf.write

    def spy_write(file, data, samplerate, **kwargs):
        captured["data"] = np.array(data, copy=True)
        return original_write(file, data, samplerate, **kwargs)

    monkeypatch.setattr("backend.midi_analysis.preview.sf.write", spy_write)

    pm = pretty_midi.PrettyMIDI()
    inst = pretty_midi.Instrument(program=0, name="Chord")
    for _ in range(8):
        inst.notes.append(pretty_midi.Note(velocity=127, pitch=69, start=0.0, end=0.5))
    pm.instruments.append(inst)

    wav_bytes = synthesize_track_preview(pm, track_index=0, max_seconds=1.0)

    assert "data" in captured
    assert np.max(np.abs(captured["data"])) <= 1.0

    audio, _ = sf.read(io.BytesIO(wav_bytes))
    assert np.max(np.abs(audio)) <= 1.0

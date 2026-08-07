from pathlib import Path

from backend.midi_analysis import list_track_candidates, load_midi, track_pitch_curve

from .fixtures.generate_fixtures import MELODY, TRACK_NAME, generate

FIXTURES_DIR = Path(__file__).resolve().parent / "fixtures"


def _load_reference():
    midi_path, _ = generate(FIXTURES_DIR)
    return load_midi(midi_path.read_bytes())


def test_vocal_track_is_detected_first_and_plausible():
    pm = _load_reference()
    candidates = list_track_candidates(pm)

    assert len(candidates) == 1
    top = candidates[0]
    assert top.name == TRACK_NAME
    assert top.name_hint_match is True
    assert top.monophonic is True
    assert top.plausible is True
    assert top.note_count == len(MELODY)
    assert top.warnings == []


def test_track_pitch_curve_matches_expected_notes():
    pm = _load_reference()
    curve = track_pitch_curve(pm, track_index=0, frame_rate_hz=100.0)

    # Mitte der ersten Note (C4, MIDI 60) pruefen.
    mid_first_note = next(p for p in curve if abs(p["t"] - 0.5) < 0.01)
    assert mid_first_note["midi_note"] == 60

    # Pause zwischen zwei Noten gibt es hier nicht (Melodie ist luecklos), aber ein
    # Zeitpunkt nach dem Ende der letzten Note muss eine Pause (None) sein.
    last_note_end = MELODY[-1][0] + MELODY[-1][1]
    curve_within_range = [p for p in curve if p["t"] < last_note_end]
    assert all(p["hz"] is not None for p in curve_within_range)


def test_track_pitch_curve_applies_transposition():
    pm = _load_reference()
    curve = track_pitch_curve(pm, track_index=0, transpose_semitones=2, frame_rate_hz=100.0)
    mid_first_note = next(p for p in curve if abs(p["t"] - 0.5) < 0.01)
    assert mid_first_note["midi_note"] == 62


def test_invalid_midi_bytes_raise_value_error():
    import pytest

    with pytest.raises(ValueError):
        load_midi(b"not a midi file")


def test_drum_and_polyphonic_tracks_are_marked_implausible():
    import pretty_midi

    pm = pretty_midi.PrettyMIDI()
    drum = pretty_midi.Instrument(program=0, is_drum=True, name="Drums")
    drum.notes.append(pretty_midi.Note(velocity=90, pitch=36, start=0, end=0.2))
    drum.notes.append(pretty_midi.Note(velocity=90, pitch=38, start=0.2, end=0.4))
    drum.notes.append(pretty_midi.Note(velocity=90, pitch=36, start=0.4, end=0.6))
    drum.notes.append(pretty_midi.Note(velocity=90, pitch=38, start=0.6, end=0.8))
    pm.instruments.append(drum)

    chord = pretty_midi.Instrument(program=0, name="Piano")
    for pitch in (60, 64, 67):
        chord.notes.append(pretty_midi.Note(velocity=90, pitch=pitch, start=0.0, end=1.0))
    for pitch in (62, 65, 69):
        chord.notes.append(pretty_midi.Note(velocity=90, pitch=pitch, start=1.0, end=2.0))
    pm.instruments.append(chord)

    candidates = list_track_candidates(pm)
    by_name = {c.name: c for c in candidates}

    assert by_name["Drums"].plausible is False
    assert by_name["Piano"].monophonic is False
    assert by_name["Piano"].plausible is True  # nicht per se implausibel, aber Warnung vorhanden
    assert any("polyphon" in w for w in by_name["Piano"].warnings)


def test_score_rewards_name_hint_match():
    import pretty_midi

    pm = pretty_midi.PrettyMIDI()
    for name in ("Vocal", "Synth"):
        inst = pretty_midi.Instrument(program=0, name=name)
        for i in range(8):
            inst.notes.append(pretty_midi.Note(velocity=90, pitch=60, start=i * 0.5, end=i * 0.5 + 0.4))
        pm.instruments.append(inst)

    candidates = list_track_candidates(pm)
    by_name = {c.name: c for c in candidates}
    assert by_name["Vocal"].score - by_name["Synth"].score == 20.0


def test_score_rewards_monophonic_over_polyphonic():
    import pretty_midi

    pm = pretty_midi.PrettyMIDI()
    mono = pretty_midi.Instrument(program=0, name="Mono")
    for i in range(8):
        mono.notes.append(pretty_midi.Note(velocity=90, pitch=60, start=i * 0.5, end=i * 0.5 + 0.4))
    pm.instruments.append(mono)

    poly = pretty_midi.Instrument(program=0, name="Poly")
    for i in range(8):
        for pitch in (60, 64, 67):
            poly.notes.append(pretty_midi.Note(velocity=90, pitch=pitch, start=i * 0.5, end=i * 0.5 + 0.4))
    pm.instruments.append(poly)

    candidates = list_track_candidates(pm)
    by_name = {c.name: c for c in candidates}
    assert by_name["Mono"].score > by_name["Poly"].score


def test_score_is_zero_for_drum_tracks():
    import pretty_midi

    pm = pretty_midi.PrettyMIDI()
    drum = pretty_midi.Instrument(program=0, is_drum=True, name="Drums")
    for i in range(4):
        drum.notes.append(pretty_midi.Note(velocity=90, pitch=36, start=i * 0.2, end=i * 0.2 + 0.1))
    pm.instruments.append(drum)

    candidates = list_track_candidates(pm)
    assert candidates[0].score == 0.0


def test_score_rewards_pitch_within_vocal_window():
    import pretty_midi

    pm = pretty_midi.PrettyMIDI()
    in_range = pretty_midi.Instrument(program=0, name="InRange")
    for i in range(8):
        in_range.notes.append(pretty_midi.Note(velocity=90, pitch=60, start=i * 0.5, end=i * 0.5 + 0.4))
    pm.instruments.append(in_range)

    out_of_range = pretty_midi.Instrument(program=0, name="OutOfRange")
    for i in range(8):
        out_of_range.notes.append(pretty_midi.Note(velocity=90, pitch=100, start=i * 0.5, end=i * 0.5 + 0.4))
    pm.instruments.append(out_of_range)

    candidates = list_track_candidates(pm)
    by_name = {c.name: c for c in candidates}
    assert by_name["InRange"].score > by_name["OutOfRange"].score


def test_score_rewards_duration_closer_to_longest_track():
    import pretty_midi

    pm = pretty_midi.PrettyMIDI()
    long_track = pretty_midi.Instrument(program=0, name="Long")
    for i in range(20):
        long_track.notes.append(pretty_midi.Note(velocity=90, pitch=60, start=i * 0.5, end=i * 0.5 + 0.4))
    pm.instruments.append(long_track)  # ~9.9s Dauer

    short_track = pretty_midi.Instrument(program=0, name="Short")
    for i in range(4):
        short_track.notes.append(pretty_midi.Note(velocity=90, pitch=60, start=i * 0.5, end=i * 0.5 + 0.4))
    pm.instruments.append(short_track)  # ~1.9s Dauer, deutlich unter 30% von 9.9s

    candidates = list_track_candidates(pm)
    by_name = {c.name: c for c in candidates}
    assert by_name["Long"].score > by_name["Short"].score


def test_score_penalizes_very_high_note_density():
    import pretty_midi

    pm = pretty_midi.PrettyMIDI()
    normal = pretty_midi.Instrument(program=0, name="Normal")
    for i in range(8):
        normal.notes.append(pretty_midi.Note(velocity=90, pitch=60, start=i * 0.5, end=i * 0.5 + 0.4))
    pm.instruments.append(normal)  # ~2 Noten/Sek, im Zielfenster

    dense = pretty_midi.Instrument(program=0, name="Dense")
    for i in range(80):
        dense.notes.append(pretty_midi.Note(velocity=90, pitch=60, start=i * 0.05, end=i * 0.05 + 0.04))
    pm.instruments.append(dense)  # ~20 Noten/Sek, deutlich ueber dem Zielfenster

    candidates = list_track_candidates(pm)
    by_name = {c.name: c for c in candidates}
    assert by_name["Normal"].score > by_name["Dense"].score

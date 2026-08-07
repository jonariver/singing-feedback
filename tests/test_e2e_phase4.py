"""End-to-End-Test fuer die Phase-4-Bewertungs-Engine (Kernpaket).

Nutzt dieselbe synthetische Fixture wie test_e2e_phase3.py. Prueft, dass alle vier
Kernpaket-Metriken die bekannten, absichtlich eingebauten Abweichungen korrekt
erkennen (siehe fixtures/generate_fixtures.py: MELODY-Kommentare).
"""

from __future__ import annotations

from pathlib import Path

from backend.audio_io import load_audio_signal
from backend.midi_analysis import load_midi, track_pitch_curve
from backend.pitch_detection import pitch_curve_from_signal
from backend.scoring import score_performance
from backend.sync import align_curves, onset_envelope_from_midi_track, onset_envelope_from_signal

from .fixtures.generate_fixtures import generate

FIXTURES_DIR = Path(__file__).resolve().parent / "fixtures"


def test_scoring_matches_fixture_expectations():
    midi_path, wav_path = generate(FIXTURES_DIR)

    pm = load_midi(midi_path.read_bytes())
    target_curve = track_pitch_curve(pm, track_index=0, frame_rate_hz=100.0)
    target_envelope = onset_envelope_from_midi_track(pm, track_index=0, frame_rate_hz=100.0)

    y, sr = load_audio_signal(wav_path.read_bytes(), filename_hint="test_vocal.wav")
    sung_curve = pitch_curve_from_signal(y, sr, frame_rate_hz=100.0)
    sung_envelope = onset_envelope_from_signal(y, sr, frame_rate_hz=100.0)

    aligned_sung_curve = align_curves(
        target_curve, target_envelope, sung_curve, sung_envelope,
    )["sung_curve"]

    score = score_performance(target_curve, aligned_sung_curve)
    notes = score["notes"]

    assert len(notes) == 5
    assert [n["target_midi_note"] for n in notes] == [60, 64, 67, 64, 60]
    assert not any(n["missed"] for n in notes)

    # Note 0 (t=0.0-1.0): korrekt gesungen.
    assert notes[0]["cents_deviation"]["classification"] == "green"
    assert notes[0]["timing"]["classification"] == "on_time"
    assert notes[0]["stability"]["flag"] is False
    assert notes[0]["phrase_end_drift"]["flag"] is False

    # Note 1 (t=1.0-2.0): konstant 40 Cent zu tief - gelb, aber kein Drift (Fehler
    # ist ueber die ganze Note gleich gross, nicht ansteigend am Ende).
    assert notes[1]["cents_deviation"]["classification"] == "yellow"
    assert -55 <= notes[1]["cents_deviation"]["value"] <= -25
    assert notes[1]["timing"]["classification"] == "on_time"
    assert notes[1]["phrase_end_drift"]["flag"] is False

    # Note 2 (t=2.0-3.0): 150ms zu frueh, aber tonhoehen-genau.
    assert notes[2]["cents_deviation"]["classification"] == "green"
    assert notes[2]["timing"]["classification"] == "too_early"
    assert notes[2]["timing"]["deviation_ms"] is not None
    assert 100 <= notes[2]["timing"]["deviation_ms"] <= 200

    # Note 3 (t=3.0-4.2): driftet erst in den letzten 300ms - Median bleibt gruen,
    # der Drift wird aber als eigenes Flag erkannt.
    assert notes[3]["cents_deviation"]["classification"] == "green"
    assert notes[3]["timing"]["classification"] == "on_time"
    assert notes[3]["stability"]["flag"] is False
    assert notes[3]["phrase_end_drift"]["flag"] is True
    assert notes[3]["phrase_end_drift"]["direction"] == "down"

    # Note 4 (t=4.2-5.0): korrekt gesungen.
    assert notes[4]["cents_deviation"]["classification"] == "green"
    assert notes[4]["timing"]["classification"] == "on_time"

    summary = score["summary"]
    assert summary["missed_count"] == 0
    assert summary["cents_yellow"] == 1
    assert summary["cents_red"] == 0
    assert summary["timing_flagged_count"] == 1
    assert summary["phrase_end_drift_flagged_count"] == 1
    assert summary["stability_flagged_count"] == 0
    assert set(summary["problem_tags"]) == {"timingprobleme", "absinkende_phrasenenden"}

    # Note 2 (150ms zu frueh) hat eine DTW-Zeitkorrektur an der Notenschwelle - siehe
    # den "Nachtrag" in docs/superpowers/specs/2026-08-07-glide-detection-design.md.
    # Die dritte Gate-Bedingung (timing_classification == "on_time") schliesst genau
    # diese Note von der Glide-Pruefung aus.
    assert notes[2]["glide"]["applicable"] is False
    assert summary["glide_flagged_count"] == 0


if __name__ == "__main__":
    test_scoring_matches_fixture_expectations()
    print("Phase-4-Scoring-Test erfolgreich.")

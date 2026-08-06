"""End-to-End-Test fuer die Phase-3-DTW-Ausrichtung.

Nutzt dieselben synthetischen Fixtures wie test_e2e_phase1.py. Kernaussage: die
absichtlich 150ms zu frueh gesungene Note 2 (siehe fixtures/generate_fixtures.py,
MELODY-Kommentare) wird durch align_curves() korrekt auf die Zielzeit zurueckgemappt,
waehrend unveraenderte Noten (0 und 4) nahe ihrer eigenen Rohzeit bleiben.
"""

from __future__ import annotations

from pathlib import Path

from backend.audio_io import load_audio_signal
from backend.midi_analysis import load_midi, track_pitch_curve
from backend.pitch_detection import pitch_curve_from_signal
from backend.sync import align_curves, onset_envelope_from_midi_track, onset_envelope_from_signal

from .fixtures.generate_fixtures import generate

FIXTURES_DIR = Path(__file__).resolve().parent / "fixtures"


def _closest_aligned_delta(aligned_curve: list[dict], target_t: float) -> float:
    frame = min(aligned_curve, key=lambda p: abs(p["t"] - target_t))
    assert frame["aligned_t"] is not None, f"kein Alignment fuer Frame bei t={frame['t']}"
    return frame["aligned_t"] - frame["t"]


def test_dtw_alignment_recovers_early_onset_and_leaves_correct_notes_unshifted():
    midi_path, wav_path = generate(FIXTURES_DIR)

    pm = load_midi(midi_path.read_bytes())
    target_curve = track_pitch_curve(pm, track_index=0, frame_rate_hz=100.0)
    target_envelope = onset_envelope_from_midi_track(pm, track_index=0, frame_rate_hz=100.0)

    y, sr = load_audio_signal(wav_path.read_bytes(), filename_hint="test_vocal.wav")
    sung_curve = pitch_curve_from_signal(y, sr, frame_rate_hz=100.0)
    sung_envelope = onset_envelope_from_signal(y, sr, frame_rate_hz=100.0)

    result = align_curves(target_curve, target_envelope, sung_curve, sung_envelope)
    aligned_curve = result["sung_curve"]

    # Note 2 (G4) wird 150ms zu frueh gesungen (t~1.85s statt 2.0s) - das Alignment
    # muss diesen Frame um ~+0.15s in Richtung Zielzeit verschieben.
    delta_early_note = _closest_aligned_delta(aligned_curve, target_t=1.85)
    assert 0.08 <= delta_early_note <= 0.22, (
        f"erwartete ~+0.15s Korrektur fuer die zu frueh gesungene Note, war {delta_early_note:.3f}s"
    )

    # Note 0 und Note 4 werden korrekt (unverschoben) gesungen - keine grosse Korrektur.
    delta_note0 = _closest_aligned_delta(aligned_curve, target_t=0.5)
    delta_note4 = _closest_aligned_delta(aligned_curve, target_t=4.5)
    assert abs(delta_note0) < 0.08, f"unveraenderte Note 0 wurde faelschlich verschoben: {delta_note0:.3f}s"
    assert abs(delta_note4) < 0.08, f"unveraenderte Note 4 wurde faelschlich verschoben: {delta_note4:.3f}s"


if __name__ == "__main__":
    test_dtw_alignment_recovers_early_onset_and_leaves_correct_notes_unshifted()
    print("Phase-3-DTW-Alignment-Test erfolgreich.")

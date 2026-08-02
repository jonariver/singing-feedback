"""End-to-End-Test fuer den vertikalen Phase-1-Prototyp.

Nutzt ausschliesslich die synthetisch erzeugten Fixtures (tests/fixtures) und deckt
den vollen Phase-1-Weg ab: MIDI laden -> Spur waehlen -> Zielkurve -> Aufnahme
analysieren -> beide Kurven vorhanden und inhaltlich plausibel.

Das ist zugleich die "dokumentierte Testaufnahme" aus Akzeptanzkriterium 10:
reproduzierbar per ``pytest`` oder direkt per ``python -m tests.test_e2e_phase1``.
Siehe README.md fuer die Kurzfassung des Ablaufs.
"""

from __future__ import annotations

from pathlib import Path

from backend.midi_analysis import list_track_candidates, load_midi, track_pitch_curve
from backend.pitch_detection import analyze_pitch

from .fixtures.generate_fixtures import MELODY, generate

FIXTURES_DIR = Path(__file__).resolve().parent / "fixtures"


def _cents_diff(hz_a: float, hz_b: float) -> float:
    import math
    return 1200 * math.log2(hz_a / hz_b)


def test_full_pipeline_end_to_end():
    midi_path, wav_path = generate(FIXTURES_DIR)

    # 1) MIDI hochladen + Spur erkennen (entspricht POST /api/midi/upload).
    pm = load_midi(midi_path.read_bytes())
    candidates = list_track_candidates(pm)
    assert len(candidates) == 1 and candidates[0].plausible

    # 2) Zielkurve fuer die gewaehlte Spur (entspricht GET /api/midi/{id}/track-curve).
    target_curve = track_pitch_curve(pm, track_index=0, frame_rate_hz=100.0)
    assert len(target_curve) > 0

    # 3) Aufnahme analysieren (entspricht POST /api/audio/analyze).
    sung_curve = analyze_pitch(wav_path.read_bytes(), filename_hint="test_vocal.wav")
    assert len(sung_curve) > 0

    # 4) Plausibilitaetscheck der bewusst eingebauten Abweichungen (siehe generate_fixtures.MELODY):
    #    Note 0 (t=0.0-1.0, korrekt) sollte nah an der Zielfrequenz liegen.
    target_by_t = {round(p["t"], 1): p["hz"] for p in target_curve if p["hz"]}
    sung_by_t = {round(p["t"], 1): p["hz"] for p in sung_curve if p["hz"]}

    common_times = sorted(set(target_by_t) & set(sung_by_t))
    assert len(common_times) > 10, "zu wenig ueberlappende Zeitpunkte fuer einen sinnvollen Vergleich"

    # Note 0: bei t=0.5 sollte die Abweichung klein sein (korrekt gesungen).
    t_correct = min(common_times, key=lambda t: abs(t - 0.5))
    deviation_correct = abs(_cents_diff(sung_by_t[t_correct], target_by_t[t_correct]))
    assert deviation_correct < 30, "erwartete kleine Abweichung bei der korrekt gesungenen Note"

    # Note 1 (t=1.0-2.0): bewusst 40 Cent zu tief -> muss klar messbar sein.
    t_flat = min((t for t in common_times if 1.2 <= t <= 1.8), key=lambda t: abs(t - 1.5))
    deviation_flat = _cents_diff(sung_by_t[t_flat], target_by_t[t_flat])
    assert deviation_flat < -25, "die absichtlich zu tiefe Note wurde nicht als zu tief erkannt"


if __name__ == "__main__":
    test_full_pipeline_end_to_end()
    print("Phase-1-End-to-End-Test erfolgreich.")

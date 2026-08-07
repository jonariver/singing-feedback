"""Tests fuer die DTW-Ausrichtung (Phase 3): Onset-Huellkurven + align_curves."""

from __future__ import annotations

from pathlib import Path

import numpy as np
import pretty_midi
import pytest

from backend.audio_io import load_audio_signal
from backend.pitch_detection import pitch_curve_from_signal
from backend.sync import (
    MAX_DURATION_RATIO,
    align_curves,
    duration_ratio_exceeds_limit,
    onset_envelope_from_midi_track,
    onset_envelope_from_signal,
)
from backend.midi_analysis import track_pitch_curve

from .fixtures.generate_fixtures import generate_pause_test_wav

FIXTURES_DIR = Path(__file__).resolve().parent / "fixtures"


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


def test_onset_envelope_from_midi_track_onset_near_track_end_not_dropped():
    """Regression test: ensure onsets near track end are not silently dropped due to rounding.

    Verifies that onset_frame uses consistent floor semantics with n_frames calculation,
    so that notes ending close to track's end_time have their onsets preserved.
    """
    # Create a MIDI with a note starting near the end: start=1.006, end=1.007
    # At frame_rate_hz=100, step=0.01:
    # - n_frames = int(1.007/0.01)+1 = int(100.7)+1 = 101
    # - onset_frame = int(1.006/0.01) = int(100.6) = 100 (floor, not round)
    # With round() (wrong), onset_frame = 101, which >= n_frames would be skipped.
    pm = pretty_midi.PrettyMIDI()
    inst = pretty_midi.Instrument(program=53, name="Vocal")
    inst.notes.append(pretty_midi.Note(velocity=90, pitch=60, start=1.006, end=1.007))
    pm.instruments.append(inst)

    env = onset_envelope_from_midi_track(pm, track_index=0, frame_rate_hz=100.0, decay_seconds=0.06)

    # Verify the note's onset frame (100 = int(1.006/0.01)) has a peak value >= decay kernel's maximum
    # The decay kernel starts at exp(-3.0*0/6) = exp(0) = 1.0
    assert env[100] == pytest.approx(1.0), "Onset at frame 100 should peak at 1.0, not be silently dropped"


def test_align_curves_recovers_early_onset_offset():
    step = 0.01  # 100Hz
    n = 200
    target_curve = [{"t": round(i * step, 3), "hz": 440.0, "midi_note": 69} for i in range(n)]
    target_envelope = [0.0] * n
    target_envelope[50] = 1.0  # Zielereignis bei t=0.50s

    sung_curve = [
        {"t": round(i * step, 3), "hz": 440.0, "voiced": True, "confidence": 0.9}
        for i in range(n)
    ]
    sung_envelope = [0.0] * n
    sung_envelope[35] = 1.0  # dasselbe Ereignis, aber 150ms (15 Frames) zu frueh (t=0.35s)

    result = align_curves(target_curve, target_envelope, sung_curve, sung_envelope)

    assert result["target_duration"] == target_curve[-1]["t"]
    aligned_t = result["sung_curve"][35]["aligned_t"]
    assert aligned_t is not None
    assert abs(aligned_t - 0.50) < 0.03


def test_align_curves_recovers_offset_at_lower_envelope_rate():
    # Gleiches Szenario wie test_align_curves_recovers_early_onset_offset, aber mit
    # einer von der 100Hz-Kurven-Rate entkoppelten, groeberen 25Hz-Envelope-Rate -
    # Kurven bleiben bei 100Hz (n=200 Frames / 2.0s), Envelope-Arrays sind jetzt nur
    # n=50 lang (ebenfalls 2.0s, aber bei 25Hz).
    step = 0.01
    n_curve = 200
    target_curve = [{"t": round(i * step, 3), "hz": 440.0, "midi_note": 69} for i in range(n_curve)]
    sung_curve = [
        {"t": round(i * step, 3), "hz": 440.0, "voiced": True, "confidence": 0.9}
        for i in range(n_curve)
    ]

    envelope_rate = 25.0
    n_env = 50
    target_envelope = [0.0] * n_env
    target_envelope[12] = 1.0  # Zielereignis bei t=0.48s
    sung_envelope = [0.0] * n_env
    sung_envelope[8] = 1.0  # dasselbe Ereignis 160ms zu frueh, bei t=0.32s

    result = align_curves(
        target_curve, target_envelope, sung_curve, sung_envelope,
        envelope_frame_rate_hz=envelope_rate,
    )
    # Kurven-Frame 32 (t=0.32s) ist exakt der Sung-Envelope-Anker (Frame 8 bei 25Hz).
    aligned_t = result["sung_curve"][32]["aligned_t"]
    assert aligned_t is not None
    assert aligned_t == pytest.approx(0.48, abs=0.01)


def test_align_curves_interpolates_between_envelope_anchors_instead_of_stepping():
    # Gleicher Aufbau wie oben, plus ein zweites, exakt uebereinstimmendes Ereignis bei
    # Envelope-Frame 24 (t=0.96s auf beiden Seiten) - das erzeugt einen laengeren
    # diagonalen (1:1) Pfadabschnitt danach. Kurven-Frames 52-56 (t=0.52-0.56s) liegen
    # in diesem diagonalen Abschnitt zwischen zwei benachbarten Envelope-Ankern mit
    # UNTERSCHIEDLICHEN Zielzeiten (0.52s und 0.56s) - bei echter linearer
    # Interpolation muessen die 5 Kurven-Frames dazwischen 5 verschiedene,
    # kontinuierlich steigende aligned_t-Werte bekommen, nicht denselben Stufenwert.
    # (Verifiziert per Hand gegen echtes librosa.sequence.dtw-Verhalten, nicht geraten -
    # falls eine spaetere librosa-Version den Warping-Pfad fuer dieses exakte Szenario
    # anders backtrackt, das Kernkriterium [5 verschiedene, aufsteigende Werte im
    # Fenster] beibehalten und die Frame-Indizes bei Bedarf anpassen.)
    step = 0.01
    n_curve = 200
    target_curve = [{"t": round(i * step, 3), "hz": 440.0, "midi_note": 69} for i in range(n_curve)]
    sung_curve = [
        {"t": round(i * step, 3), "hz": 440.0, "voiced": True, "confidence": 0.9}
        for i in range(n_curve)
    ]

    envelope_rate = 25.0
    n_env = 50
    target_envelope = [0.0] * n_env
    target_envelope[12] = 1.0
    target_envelope[24] = 1.0
    sung_envelope = [0.0] * n_env
    sung_envelope[8] = 1.0
    sung_envelope[24] = 1.0

    result = align_curves(
        target_curve, target_envelope, sung_curve, sung_envelope,
        envelope_frame_rate_hz=envelope_rate,
    )
    aligned = result["sung_curve"]
    window = [aligned[i]["aligned_t"] for i in range(52, 57)]
    assert all(v is not None for v in window)
    assert window == [pytest.approx(0.52 + 0.01 * k, abs=1e-9) for k in range(5)]
    assert len(set(window)) == 5, (
        "aligned_t sollte zwischen den DTW-Ankern kontinuierlich interpolieren, "
        "nicht in Stufen springen"
    )


def test_align_curves_handles_empty_input_without_raising():
    result = align_curves([], [], [], [])
    assert result == {"sung_curve": [], "target_duration": 0.0}


def test_align_curves_handles_very_short_curves_without_band_related_crash():
    # 3 Frames je Seite - bei DTW_BAND_RADIUS=0.1 rundet der Bandradius auf 0 Frames,
    # was librosa.sequence.dtw ohne die Absicherung in align_curves() zum Werfen von
    # ParameterError bringen wuerde.
    target_curve = [{"t": round(i * 0.01, 3), "hz": 440.0, "midi_note": 69} for i in range(3)]
    target_envelope = [0.0, 1.0, 0.0]
    sung_curve = [
        {"t": round(i * 0.01, 3), "hz": 440.0, "voiced": True, "confidence": 0.9}
        for i in range(3)
    ]
    sung_envelope = [0.0, 1.0, 0.0]

    result = align_curves(target_curve, target_envelope, sung_curve, sung_envelope)

    assert len(result["sung_curve"]) == 3
    assert all(frame["aligned_t"] is not None for frame in result["sung_curve"])


def test_duration_ratio_exceeds_limit_rejects_disproportionate_target():
    # Ziel (300s) ist deutlich mehr als MAX_DURATION_RATIO x so lang wie die Aufnahme (10s).
    assert duration_ratio_exceeds_limit(target_duration=300.0, sung_duration=10.0) is True


def test_duration_ratio_exceeds_limit_allows_comparable_durations():
    # Ziel ist laenger als die Aufnahme, aber innerhalb des erlaubten Verhaeltnisses.
    assert duration_ratio_exceeds_limit(target_duration=20.0, sung_duration=10.0) is False


def test_duration_ratio_exceeds_limit_is_strict_at_the_boundary():
    sung_duration = 10.0
    exactly_at_limit = MAX_DURATION_RATIO * sung_duration
    assert duration_ratio_exceeds_limit(exactly_at_limit, sung_duration) is False
    assert duration_ratio_exceeds_limit(exactly_at_limit + 0.01, sung_duration) is True


def test_duration_ratio_exceeds_limit_ignores_zero_or_negative_durations():
    # Leere Kurven (Dauer 0) werden hier bewusst nicht abgelehnt - dafuer gibt es
    # bereits andere Fehlerpfade (leere Kurve -> align_curves() liefert leeres Ergebnis).
    assert duration_ratio_exceeds_limit(target_duration=0.0, sung_duration=10.0) is False
    assert duration_ratio_exceeds_limit(target_duration=10.0, sung_duration=0.0) is False


def test_align_curves_self_alignment_stays_near_zero_through_a_long_pause():
    """Realer Bug: DTW driftete auf einer 61s-Aufnahme mit 20s Stille um bis zu 18.7s
    (siehe docs/superpowers/specs/2026-08-06-dtw-drift-band-fix-design.md).

    Reproduziert das in Miniatur: eine durchgehende Zielspur (Referenz/Instrumental
    laeuft weiter) gegen eine Gesangsspur mit einer echten 12s-Stille (Saenger
    pausiert) - beide teilen dieselben Randnoten vor/nach der Luecke. Ein sauber
    funktionierendes Alignment sollte `aligned_t - t` auch waehrend/nach der Pause in
    einer plausiblen Groessenordnung halten (siehe Design-Dokument, Abschnitt
    "Kalibrierung des Bandradius": einstellige Sekundenzahl, nicht die beobachteten
    ~19s).

    Hinweis zur Abweichung vom urspruenglichen Plan: eine woertliche "Selbst-
    Ausrichtung" (identisches Kurven-/Huellkurven-Objekt fuer Ziel UND Gesang) wurde
    zuerst probiert, reproduziert den Bug aber nie - der DTW-Diagonalpfad hat dann per
    Konstruktion immer Gesamtkosten 0 und ist damit stets (mindestens) gleich gut wie
    jede Abweichung, librosa's Backtracking loest das konsistent zugunsten der
    Diagonale auf (max_drift exakt 0.0, gemessen ueber Pausenlaengen von 12-30s). Siehe
    Task-1-Report fuer die Messwerte sowie generate_fixtures.py fuer den Kommentar zur
    Fixture."""
    target_path, sung_path = generate_pause_test_wav(FIXTURES_DIR)

    target_y, target_sr = load_audio_signal(
        target_path.read_bytes(), filename_hint="test_pause_target.wav"
    )
    target_curve = pitch_curve_from_signal(target_y, target_sr, frame_rate_hz=100.0)
    target_envelope = onset_envelope_from_signal(target_y, target_sr, frame_rate_hz=100.0)

    sung_y, sung_sr = load_audio_signal(
        sung_path.read_bytes(), filename_hint="test_pause_sung.wav"
    )
    sung_curve = pitch_curve_from_signal(sung_y, sung_sr, frame_rate_hz=100.0)
    sung_envelope = onset_envelope_from_signal(sung_y, sung_sr, frame_rate_hz=100.0)

    result = align_curves(target_curve, target_envelope, sung_curve, sung_envelope)
    aligned = result["sung_curve"]

    deltas = [abs(f["aligned_t"] - f["t"]) for f in aligned if f["aligned_t"] is not None]
    assert deltas, "kein einziger Frame wurde ausgerichtet - Fixture oder Pipeline kaputt"
    max_drift = max(deltas)
    assert max_drift < 3.0, (
        f"Ausrichtung sollte auch durch die Gesangspause hindurch nahe an der "
        f"Diagonale bleiben (Drift < 3s, siehe Design-Dokument: 'einstellige "
        f"Sekundenzahl'), tatsaechlich max. {max_drift:.2f}s - DTW driftet "
        f"waehrend/nach der Pause."
    )

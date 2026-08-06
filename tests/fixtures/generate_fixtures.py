"""Erzeugt reproduzierbare, urheberrechtsfreie Testdaten fuer die Pipeline:

- ``test_reference.mid``: eine kurze, frei erfundene 5-Noten-Melodie auf einer
  einzelnen, als "Vocal" benannten monophonen Spur.
- ``test_vocal.wav``: eine synthetische "Gesangs"-Aufnahme, die dieser Melodie
  folgt, aber bewusst eingebaute Abweichungen enthaelt (siehe MELODY-Kommentare
  unten) - genau das, was spaetere Phasen (Sync/Scoring) erkennen sollen.

Bewusst synthetisch statt eines echten/geschuetzten Songs (siehe Leitplanke
"keine automatische Beschaffung geschuetzter Songs" und Akzeptanzkriterium 10:
reproduzierbare Testaufnahme). Deterministisch (kein Zufall), damit Tests stabil
bleiben.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
import pretty_midi
import soundfile as sf

FIXTURES_DIR = Path(__file__).resolve().parent
SAMPLE_RATE = 22050

# (start_s, duration_s, midi_note) - eine kurze, freie Fantasiemelodie (C-E-G-E-C).
MELODY = [
    (0.0, 1.0, 60),  # C4 - wird korrekt "gesungen"
    (1.0, 1.0, 64),  # E4 - wird 40 Cent zu tief gesungen
    (2.0, 1.0, 67),  # G4 - wird 150ms zu frueh eingesetzt
    (3.0, 1.2, 64),  # E4 - gehaltener Ton, driftet zum Ende hin ~100 Cent nach unten ab
    (4.2, 0.8, 60),  # C4 - wird korrekt "gesungen"
]

TRACK_NAME = "Vocal"


def build_test_midi() -> pretty_midi.PrettyMIDI:
    pm = pretty_midi.PrettyMIDI()
    instrument = pretty_midi.Instrument(program=53, name=TRACK_NAME)  # 53 = Voice Oohs
    for start, duration, note in MELODY:
        instrument.notes.append(
            pretty_midi.Note(velocity=90, pitch=note, start=start, end=start + duration)
        )
    pm.instruments.append(instrument)
    return pm


def _semitone_ratio(cents: float) -> float:
    return 2 ** (cents / 1200.0)


def _sine_segment(freq_fn, duration: float, sr: int, fade: float = 0.02) -> np.ndarray:
    n = int(duration * sr)
    t = np.arange(n) / sr
    freq = freq_fn(t)
    # Phase durch Integration der (ggf. zeitvariablen) Frequenz, sonst gibt es bei
    # Frequenzaenderungen (Drift/Glide) Sprungstellen im Signal.
    phase = 2 * np.pi * np.cumsum(freq) / sr
    signal = 0.2 * np.sin(phase)

    fade_n = max(1, int(fade * sr))
    envelope = np.ones(n)
    envelope[:fade_n] = np.linspace(0, 1, fade_n)
    envelope[-fade_n:] = np.linspace(1, 0, fade_n)
    return signal * envelope


def build_test_vocal_wav(sr: int = SAMPLE_RATE) -> np.ndarray:
    total_duration = MELODY[-1][0] + MELODY[-1][1]
    audio = np.zeros(int(total_duration * sr) + 1)

    for i, (start, duration, note) in enumerate(MELODY):
        base_hz = pretty_midi.note_number_to_hz(note)

        if i == 1:
            # 40 Cent zu tief, konstant ueber die gesamte Notendauer.
            freq_fn = lambda t, hz=base_hz: np.full_like(t, hz * _semitone_ratio(-40))
            note_start = start
            note_duration = duration
        elif i == 2:
            # 150ms zu frueher Einsatz, ansonsten korrekte Tonhoehe.
            freq_fn = lambda t, hz=base_hz: np.full_like(t, hz)
            note_start = start - 0.15
            note_duration = duration + 0.15
        elif i == 3:
            # Gehaltener Ton, der in den letzten 300ms um 100 Cent absackt.
            def freq_fn(t, hz=base_hz, dur=duration):
                drift_start = max(0.0, dur - 0.3)
                cents = np.where(t >= drift_start, -100.0 * (t - drift_start) / 0.3, 0.0)
                return hz * _semitone_ratio(cents)
            note_start = start
            note_duration = duration
        else:
            freq_fn = lambda t, hz=base_hz: np.full_like(t, hz)
            note_start = start
            note_duration = duration

        segment = _sine_segment(freq_fn, note_duration, sr)
        start_sample = int(note_start * sr)
        end_sample = start_sample + len(segment)
        if end_sample > len(audio):
            audio = np.pad(audio, (0, end_sample - len(audio)))
        audio[start_sample:end_sample] += segment

    return audio


def generate(output_dir: Path = FIXTURES_DIR) -> tuple[Path, Path]:
    output_dir.mkdir(parents=True, exist_ok=True)

    midi_path = output_dir / "test_reference.mid"
    build_test_midi().write(str(midi_path))

    wav_path = output_dir / "test_vocal.wav"
    audio = build_test_vocal_wav()
    sf.write(str(wav_path), audio, SAMPLE_RATE)

    return midi_path, wav_path


# --- Pausen-Fixture (Bugfix: DTW-Drift bei Pausen, Phase 3) ---
#
# Simuliert einen Instrumentalteil (der reale, auf einem Telefon beobachtete Fall:
# 61s-Aufnahme mit 20s Stille, bis zu 18.7s DTW-Drift).
#
# Abweichung von der urspruenglich geplanten Herangehensweise (siehe Implementierungs-
# plan/Task-1-Brief): dort war eine reine "Selbst-Ausrichtung" vorgesehen - dieselbe
# Kurve/Huellkurve wortwoertlich (dasselbe Python-Objekt) sowohl als Ziel- wie auch als
# Gesangskurve an align_curves() uebergeben. Das erwies sich beim Ausprobieren als
# fundamental untauglich, den Bug zu reproduzieren, und zwar unabhaengig von
# Pausenlaenge/Melodie: wenn Ziel- und Gesangs-Huellkurve identisch sind, hat der
# DTW-Diagonalpfad IMMER Gesamtkosten 0 (jede Abweichung von der Diagonale kann
# hoechstens gleich gute, nie bessere Kosten erreichen) - librosa.sequence.dtw's
# Backtracking loest diesen (auch bei 12-30s Pause reproduzierbar getesteten) Fall
# konsistent zugunsten der Diagonale auf, siehe Task-1-Report fuer die Messwerte. Das
# stimmt mit der Kalibrierungs-Anleitung im Design-Dokument
# (docs/superpowers/specs/2026-08-06-dtw-drift-band-fix-design.md, Abschnitt
# "Kalibrierung des Bandradius") ueberein, die fuer die Pausen-Fixture explizit "eine
# eingebaute stille Luecke ... in der gesungenen Spur (nicht in der Zielspur)" verlangt.
#
# Deshalb baut diese Fixture zwei tatsaechlich unterschiedliche Aufnahmen: eine
# durchgehende "Ziel"/Referenzspur (spielt ueber die volle Dauer, wie ein Instrumental-
# Playback, das waehrend der Gesangspause weiterlaeuft) und eine "Gesangs"-Spur mit
# einer echten 12s-Stille in der Mitte (der Saenger pausiert, wie im real beobachteten
# Fall). Nur so entsteht ein echtes, deterministisches Kostengefaelle, das den
# unbegrenzten DTW-Pfad zum Wegdriften bringt (siehe Task-1-Report: reproduzierbar
# mehrere Sekunden Drift statt exakt 0.0).

PAUSE_TEST_TOTAL_DURATION = 24.0

# Gesangsspur: kurze Melodie vor und nach einer echten 12s-Stille (Saenger pausiert).
_PAUSE_SUNG_MELODY = [
    (0.0, 2.0, 60),   # C4
    (2.0, 2.0, 64),   # E4
    (4.0, 2.0, 67),   # G4
    # 6.0-18.0s: Stille (Saenger pausiert, 12s Luecke)
    (18.0, 2.0, 67),  # G4
    (20.0, 2.0, 64),  # E4
    (22.0, 2.0, 60),  # C4
]

# Zielspur/Referenz: durchgehendes "Instrumental", das auch waehrend der Gesangspause
# weiterspielt - dieselben Randnoten wie die Gesangsspur, plus Fuellnoten in der Luecke.
_PAUSE_TARGET_MELODY = [
    (0.0, 2.0, 60),   # C4
    (2.0, 2.0, 64),   # E4
    (4.0, 2.0, 67),   # G4
    (6.0, 2.0, 69),   # A4
    (8.0, 2.0, 67),   # G4
    (10.0, 2.0, 64),  # E4
    (12.0, 2.0, 62),  # D4
    (14.0, 2.0, 64),  # E4
    (16.0, 2.0, 67),  # G4
    (18.0, 2.0, 67),  # G4
    (20.0, 2.0, 64),  # E4
    (22.0, 2.0, 60),  # C4
]


def _build_wav_from_melody(melody: list[tuple[float, float, int]], sr: int) -> np.ndarray:
    audio = np.zeros(int(PAUSE_TEST_TOTAL_DURATION * sr) + 1)
    for start, duration, note in melody:
        base_hz = pretty_midi.note_number_to_hz(note)
        freq_fn = lambda t, hz=base_hz: np.full_like(t, hz)
        segment = _sine_segment(freq_fn, duration, sr)
        start_sample = int(start * sr)
        end_sample = start_sample + len(segment)
        if end_sample > len(audio):
            audio = np.pad(audio, (0, end_sample - len(audio)))
        audio[start_sample:end_sample] += segment
    return audio


def build_pause_test_target_wav(sr: int = SAMPLE_RATE) -> np.ndarray:
    """Durchgehende Referenzspur (kein Gesangspausen-Loch) fuer die Pausen-Fixture."""
    return _build_wav_from_melody(_PAUSE_TARGET_MELODY, sr)


def build_pause_test_sung_wav(sr: int = SAMPLE_RATE) -> np.ndarray:
    """Gesangsspur mit einer echten 12s-Stille in der Mitte fuer die Pausen-Fixture."""
    return _build_wav_from_melody(_PAUSE_SUNG_MELODY, sr)


def generate_pause_test_wav(output_dir: Path = FIXTURES_DIR) -> tuple[Path, Path]:
    """Erzeugt die zwei WAVs der Pausen-Fixture und gibt (target_path, sung_path)
    zurueck."""
    output_dir.mkdir(parents=True, exist_ok=True)

    target_path = output_dir / "test_pause_target.wav"
    sf.write(str(target_path), build_pause_test_target_wav(), SAMPLE_RATE)

    sung_path = output_dir / "test_pause_sung.wav"
    sf.write(str(sung_path), build_pause_test_sung_wav(), SAMPLE_RATE)

    return target_path, sung_path


if __name__ == "__main__":
    midi_path, wav_path = generate()
    print(f"Erzeugt: {midi_path}")
    print(f"Erzeugt: {wav_path}")

    pause_target_path, pause_sung_path = generate_pause_test_wav()
    print(f"Erzeugt: {pause_target_path}")
    print(f"Erzeugt: {pause_sung_path}")

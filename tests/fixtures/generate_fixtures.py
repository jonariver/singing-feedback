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


if __name__ == "__main__":
    midi_path, wav_path = generate()
    print(f"Erzeugt: {midi_path}")
    print(f"Erzeugt: {wav_path}")

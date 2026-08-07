"""Sinus-/Obertonsynthesizer fuer die Spur-Hoerprobe (Phase 2).

Kein Soundfont/FluidSynth (siehe PLAN.md "Getroffene Annahmen") - additive Synthese
aus Grundton + zwei leiseren Obertoenen, mit kurzem Attack/Release pro Note gegen
Knackgeraeusche an Notengrenzen. Gedeckelt auf `max_seconds`, damit die Hoerprobe
schnell laedt und nicht die ganze (potenziell mehrminuetige) Spur rendert.
"""

from __future__ import annotations

import io

import numpy as np
import pretty_midi
import soundfile as sf

from backend.config import TRACK_PREVIEW_MAX_SECONDS, TRACK_PREVIEW_SAMPLE_RATE

_ATTACK_RELEASE_SECONDS = 0.01
_OVERTONE_AMPLITUDES = (1.0, 0.5, 0.25)  # Grundton, 1. Oberton, 2. Oberton


def _note_segment(freq_hz: float, duration_seconds: float, sample_rate: int) -> np.ndarray:
    n = max(1, int(duration_seconds * sample_rate))
    t = np.arange(n) / sample_rate
    signal = np.zeros(n)
    for harmonic, amplitude in enumerate(_OVERTONE_AMPLITUDES, start=1):
        signal += amplitude * np.sin(2 * np.pi * freq_hz * harmonic * t)
    signal = signal / sum(_OVERTONE_AMPLITUDES) * 0.2

    fade_n = max(1, min(n // 2, int(_ATTACK_RELEASE_SECONDS * sample_rate)))
    envelope = np.ones(n)
    envelope[:fade_n] = np.linspace(0, 1, fade_n)
    envelope[-fade_n:] = np.linspace(1, 0, fade_n)
    return signal * envelope


def synthesize_track_preview(
    pm: pretty_midi.PrettyMIDI,
    track_index: int,
    transpose_semitones: int = 0,
    max_seconds: float = TRACK_PREVIEW_MAX_SECONDS,
    sample_rate: int = TRACK_PREVIEW_SAMPLE_RATE,
) -> bytes:
    """Rendert die ersten `max_seconds` einer MIDI-Spur additiv zu WAV-Bytes."""
    if track_index < 0 or track_index >= len(pm.instruments):
        raise ValueError(f"Ungueltiger Spurindex: {track_index}")

    inst = pm.instruments[track_index]
    total_samples = int(max_seconds * sample_rate) + 1
    audio = np.zeros(total_samples)

    for note in inst.notes:
        if note.start >= max_seconds:
            continue
        segment_duration = min(note.end, max_seconds) - note.start
        if segment_duration <= 0:
            continue
        freq_hz = pretty_midi.note_number_to_hz(note.pitch + transpose_semitones)
        segment = _note_segment(freq_hz, segment_duration, sample_rate)

        start_sample = int(note.start * sample_rate)
        end_sample = start_sample + len(segment)
        if end_sample > len(audio):
            segment = segment[: len(audio) - start_sample]
            end_sample = len(audio)
        audio[start_sample:end_sample] += segment

    buffer = io.BytesIO()
    sf.write(buffer, audio, sample_rate, format="WAV")
    return buffer.getvalue()

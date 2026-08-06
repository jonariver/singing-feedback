"""Onset-/Energiehuellkurven fuer die DTW-Ausrichtung (Phase 3).

DTW laeuft bewusst NICHT auf der Rohtonhoehe (siehe PLAN.md, Abschnitt "Technisch
riskanteste Punkte"): ein DTW auf Rohtonhoehe wuerde genau dann versagen, wenn der
Nutzer die falsche Note singt - der Fall, den die spaetere Bewertung messen soll.
Stattdessen wird eine tonhoehen-unabhaengige Onset-Huellkurve verwendet.
"""

from __future__ import annotations

import librosa
import numpy as np
import pretty_midi


def onset_envelope_from_signal(
    y: np.ndarray, sr: int, frame_rate_hz: float = 100.0,
) -> list[float]:
    """Onset-Staerke aus echtem Audio (Gesangs- oder Referenzaufnahme).

    hop_length wird so gewaehlt, dass envelope[i] zeitlich zu Kurven-Frame i der
    pYIN-Tonhoehenkurve (pitch_curve_from_signal, gleiche frame_rate_hz) passt,
    ohne separaten Resampling-Schritt.
    """
    hop_length = max(1, int(round(sr / frame_rate_hz)))
    env = librosa.onset.onset_strength(y=y, sr=sr, hop_length=hop_length)
    return [float(v) for v in env]


def onset_envelope_from_midi_track(
    pm: pretty_midi.PrettyMIDI,
    track_index: int,
    frame_rate_hz: float = 100.0,
    decay_seconds: float = 0.06,
) -> list[float]:
    """Synthetischer Onset-Impuls-Zug aus den MIDI-Note-Startzeiten.

    Kein Audiosignal noetig (im Projekt existiert kein MIDI-Synthesizer) - die
    Onset-Zeiten sind aus den Noten bereits exakt bekannt. Frame-Anzahl/-Schritt
    sind identisch zu track_pitch_curve(), damit envelope[i] zu jener Kurve passt.
    """
    if track_index < 0 or track_index >= len(pm.instruments):
        raise ValueError(f"Ungueltiger Spurindex: {track_index}")

    inst = pm.instruments[track_index]
    if not inst.notes:
        return []

    end_time = max(n.end for n in inst.notes)
    step = 1.0 / frame_rate_hz
    n_frames = int(end_time / step) + 1

    decay_frames = max(1, int(round(decay_seconds * frame_rate_hz)))
    decay_kernel = np.exp(-3.0 * np.arange(decay_frames) / decay_frames)

    env = np.zeros(n_frames)
    for note in inst.notes:
        onset_frame = int(round(note.start / step))
        if onset_frame >= n_frames:
            continue
        span = min(decay_frames, n_frames - onset_frame)
        env[onset_frame:onset_frame + span] += decay_kernel[:span]

    return [float(v) for v in env]

"""MIDI-Parsing und Basis-Spurauswahl (Phase 1).

Bewusst noch OHNE die volle Heuristik-Bewertung aus Phase 2 (Notendichte-Score,
Dauer-Plausibilitaet, Name-Matching-Gewichtung). Phase 1 liefert nur die Rohfakten
pro Spur (monophon?, Tonumfang, Notenzahl, Dauer, Name/Instrument), damit der Nutzer
manuell eine plausible Spur waehlen kann - siehe Plan Phase 1 vs. Phase 2.
"""

from __future__ import annotations

import io
from dataclasses import dataclass, field

import pretty_midi

# Namen, nach denen bevorzugt gesucht wird (siehe Anforderung).
VOCAL_NAME_HINTS = ("vocal", "voice", "lead", "melody", "gesang", "vox", "singer")

# Ein Track mit weniger Noten als das ist fuer eine Gesangsmelodie kaum plausibel
# (reine Ein-Ton-Effektspuren o.ae.); grobe Phase-1-Grenze, keine echte Kalibrierung.
MIN_PLAUSIBLE_NOTE_COUNT = 4


@dataclass
class TrackCandidate:
    index: int
    name: str
    program: int
    is_drum: bool
    note_count: int
    pitch_min: int | None  # MIDI Notennummer
    pitch_max: int | None
    duration_seconds: float
    monophonic: bool
    name_hint_match: bool
    plausible: bool
    warnings: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        # pretty_midi/mido liefern teils numpy-Skalare (int64/float64) statt
        # eingebauter Python-Typen; pydantic/FastAPI kann diese nicht serialisieren.
        return {
            "index": int(self.index),
            "name": self.name,
            "program": int(self.program),
            "is_drum": bool(self.is_drum),
            "note_count": int(self.note_count),
            "pitch_min": int(self.pitch_min) if self.pitch_min is not None else None,
            "pitch_max": int(self.pitch_max) if self.pitch_max is not None else None,
            "pitch_min_name": pretty_midi.note_number_to_name(self.pitch_min) if self.pitch_min is not None else None,
            "pitch_max_name": pretty_midi.note_number_to_name(self.pitch_max) if self.pitch_max is not None else None,
            "duration_seconds": round(float(self.duration_seconds), 2),
            "monophonic": bool(self.monophonic),
            "name_hint_match": bool(self.name_hint_match),
            "plausible": bool(self.plausible),
            "warnings": self.warnings,
        }


def load_midi(data: bytes) -> pretty_midi.PrettyMIDI:
    """Parst MIDI-Bytes. Wirft ValueError bei kaputten/leeren Dateien statt einer
    kryptischen pretty_midi/mido-Exception."""
    try:
        return pretty_midi.PrettyMIDI(io.BytesIO(data))
    except Exception as exc:  # pretty_midi/mido werfen diverse Exception-Typen
        raise ValueError(f"MIDI-Datei konnte nicht gelesen werden: {exc}") from exc


def _is_monophonic(notes: list[pretty_midi.Note], overlap_tolerance: float = 0.02) -> bool:
    """Ueberwiegend monophon = fast keine zeitlich ueberlappenden Noten."""
    if len(notes) < 2:
        return True
    sorted_notes = sorted(notes, key=lambda n: n.start)
    overlaps = 0
    for prev, cur in zip(sorted_notes, sorted_notes[1:]):
        if cur.start < prev.end - overlap_tolerance:
            overlaps += 1
    return (overlaps / max(1, len(sorted_notes) - 1)) < 0.1


def list_track_candidates(pm: pretty_midi.PrettyMIDI) -> list[TrackCandidate]:
    """Liefert Rohfakten je Instrument-Spur, sortiert danach wie plausibel eine
    Spur als Gesangsmelodie infrage kommt (Name-Treffer und Monophonie zuerst)."""
    candidates: list[TrackCandidate] = []

    for idx, inst in enumerate(pm.instruments):
        notes = inst.notes
        note_count = len(notes)
        name = (inst.name or "").strip()
        if not name:
            name = "Schlagzeug" if inst.is_drum else pretty_midi.program_to_instrument_name(inst.program)

        warnings: list[str] = []

        if note_count == 0:
            warnings.append("Spur enthaelt keine Noten.")
            candidates.append(TrackCandidate(
                index=idx, name=name, program=inst.program, is_drum=inst.is_drum,
                note_count=0, pitch_min=None, pitch_max=None, duration_seconds=0.0,
                monophonic=True, name_hint_match=False, plausible=False, warnings=warnings,
            ))
            continue

        pitches = [n.pitch for n in notes]
        duration = max(n.end for n in notes) - min(n.start for n in notes)
        monophonic = _is_monophonic(notes)
        name_hint_match = any(hint in name.lower() for hint in VOCAL_NAME_HINTS)

        plausible = True
        if inst.is_drum:
            plausible = False
            warnings.append("Schlagzeugspur, keine Melodie.")
        if note_count < MIN_PLAUSIBLE_NOTE_COUNT:
            plausible = False
            warnings.append("Sehr wenige Noten fuer eine durchgehende Melodie.")
        if not monophonic:
            warnings.append("Spur ist ueberwiegend polyphon (klingt eher nach Akkorden als nach einer Einzelstimme).")

        candidates.append(TrackCandidate(
            index=idx, name=name, program=inst.program, is_drum=inst.is_drum,
            note_count=note_count, pitch_min=min(pitches), pitch_max=max(pitches),
            duration_seconds=duration, monophonic=monophonic,
            name_hint_match=name_hint_match, plausible=plausible, warnings=warnings,
        ))

    # Name-Treffer + monophon + plausibel zuerst, damit die wahrscheinlichste
    # Gesangsspur im Frontend oben steht (der Nutzer waehlt trotzdem selbst).
    candidates.sort(key=lambda c: (not c.name_hint_match, not c.plausible, not c.monophonic, -c.note_count))
    return candidates


def has_any_plausible_vocal_track(candidates: list[TrackCandidate]) -> bool:
    return any(c.plausible for c in candidates)


def track_pitch_curve(
    pm: pretty_midi.PrettyMIDI,
    track_index: int,
    transpose_semitones: int = 0,
    frame_rate_hz: float = 100.0,
) -> list[dict]:
    """Rendert die gewaehlte Spur als Zeit/Tonhoehe-Kurve (Sollmelodie).

    Liefert pro Zeitschritt entweder eine gehaltene Tonhoehe (Hz + MIDI-Notennummer)
    oder None fuer Pausen, in der ein Ton weder beginnt noch klingt.
    """
    if track_index < 0 or track_index >= len(pm.instruments):
        raise ValueError(f"Ungueltiger Spurindex: {track_index}")

    inst = pm.instruments[track_index]
    if not inst.notes:
        return []

    end_time = max(n.end for n in inst.notes)
    step = 1.0 / frame_rate_hz
    n_frames = int(end_time / step) + 1

    # Notenintervalle nach Startzeit sortiert fuer eine einfache Sweep-Zuordnung.
    notes_sorted = sorted(inst.notes, key=lambda n: n.start)

    curve: list[dict] = []
    active_idx = 0
    n_notes = len(notes_sorted)

    for frame in range(n_frames):
        t = frame * step
        while active_idx < n_notes - 1 and notes_sorted[active_idx].end <= t:
            active_idx += 1

        note = notes_sorted[active_idx]
        if note.start <= t < note.end:
            midi_note = note.pitch + transpose_semitones
            hz = pretty_midi.note_number_to_hz(midi_note)
            curve.append({"t": round(t, 3), "hz": round(hz, 3), "midi_note": midi_note})
        else:
            curve.append({"t": round(t, 3), "hz": None, "midi_note": None})

    return curve

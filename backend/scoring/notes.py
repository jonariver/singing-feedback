"""Noten-Segmentierung aus der Zielkurve fuer die Bewertungs-Engine (Phase 4).

Bewusst OHNE Zugriff auf echte pretty_midi.Note-Objekte/MIDI_SESSIONS: "Noten"
werden direkt aus target_curve segmentiert, damit Scoring einheitlich fuer
MIDI-Ziele (exakt, da die Kurve schon eine Stufenfunktion ist) und
Referenzaufnahme-Ziele (Naeherung ueber eine echte, verrauschte Tonhoehenkurve)
funktioniert. Bekannte Grenze: zwei direkt aufeinanderfolgende Noten derselben
Tonhoehe ohne Pause dazwischen sind mit diesem Ansatz nicht unterscheidbar.
"""

from __future__ import annotations

import math

from backend.config import (
    LAST_NOTE_TAIL_TOLERANCE_SECONDS,
    NOTE_SEGMENT_MAX_BRIDGE_GAP_FRAMES,
    NOTE_SEGMENT_MIN_DURATION_SECONDS,
    NOTE_SEGMENT_ROLLING_WINDOW_FRAMES,
    NOTE_SEGMENT_TOLERANCE_CENTS,
)


def hz_to_cents(hz: float, ref_hz: float = 440.0) -> float:
    return 1200.0 * math.log2(hz / ref_hz)


def segment_target_notes(
    target_curve: list[dict],
    frame_rate_hz: float = 100.0,
    tolerance_cents: float = NOTE_SEGMENT_TOLERANCE_CENTS,
    rolling_window_frames: int = NOTE_SEGMENT_ROLLING_WINDOW_FRAMES,
    max_bridge_gap_frames: int = NOTE_SEGMENT_MAX_BRIDGE_GAP_FRAMES,
    min_duration_seconds: float = NOTE_SEGMENT_MIN_DURATION_SECONDS,
) -> list[dict]:
    """Segmentiert target_curve in diskrete "Noten": [{index, start_t, end_t, hz, midi_note}].

    Ein stimmhafter Frame gehoert zum aktuellen Segment, wenn seine Cent-Abweichung
    vom gleitenden Median der letzten `rolling_window_frames` Frames im Segment
    innerhalb von `tolerance_cents` liegt - ein echter Notenwechsel (mehrere hundert
    Cent) schneidet sofort, langsames Drift/Vibrato reisst das Segment nicht ab.
    Unstimmhafte/leere Frames ueberbruecken eine Luecke bis `max_bridge_gap_frames`,
    danach wird das Segment geschlossen. Segmente unter `min_duration_seconds` werden
    verworfen (Rauschen bei Referenzaufnahmen, bei MIDI ein No-op).
    """
    step = 1.0 / frame_rate_hz
    raw_segments: list[list[dict]] = []
    current: list[dict] = []
    gap_count = 0

    for frame in target_curve:
        hz = frame.get("hz")
        if hz is None:
            if current:
                gap_count += 1
                if gap_count > max_bridge_gap_frames:
                    raw_segments.append(current)
                    current = []
                    gap_count = 0
            continue

        cents = hz_to_cents(hz)
        if not current:
            current = [frame]
            gap_count = 0
            continue

        window_cents = sorted(hz_to_cents(f["hz"]) for f in current[-rolling_window_frames:])
        median_cents = window_cents[len(window_cents) // 2]
        if abs(cents - median_cents) <= tolerance_cents:
            current.append(frame)
            gap_count = 0
        else:
            raw_segments.append(current)
            current = [frame]
            gap_count = 0

    if current:
        raw_segments.append(current)

    notes: list[dict] = []
    for frames in raw_segments:
        start_t = frames[0]["t"]
        end_t = frames[-1]["t"] + step
        if end_t - start_t < min_duration_seconds:
            continue
        hz_values = sorted(f["hz"] for f in frames)
        median_hz = hz_values[len(hz_values) // 2]
        midi_notes = [f["midi_note"] for f in frames if f.get("midi_note") is not None]
        if midi_notes:
            midi_note = max(set(midi_notes), key=midi_notes.count)
        else:
            midi_note = round(69 + 12 * math.log2(median_hz / 440.0))
        notes.append({
            "index": len(notes),
            "start_t": round(start_t, 3),
            "end_t": round(end_t, 3),
            "hz": round(median_hz, 3),
            "midi_note": midi_note,
        })

    return notes


def attribute_sung_frames(sung_curve: list[dict], note: dict, is_last_note: bool) -> list[dict]:
    """Sung-Frames, deren aligned_t in [note['start_t'], note['end_t']) faellt - bei
    der letzten Note um LAST_NOTE_TAIL_TOLERANCE_SECONDS nach oben erweitert (nicht
    unbegrenzt offen), damit DTW-Randeffekte keine Frames verschlucken, ohne dass
    beliebig langer Nachklang (Summen, Atmen, Ausklingen) faelschlich der letzten
    Note zugerechnet wird."""
    start_t = note["start_t"]
    end_t = note["end_t"]
    if is_last_note:
        end_t = end_t + LAST_NOTE_TAIL_TOLERANCE_SECONDS
    result = []
    for frame in sung_curve:
        aligned_t = frame.get("aligned_t")
        if aligned_t is None or aligned_t < start_t or aligned_t >= end_t:
            continue
        result.append(frame)
    return result


def cents_series(note: dict, attributed_frames: list[dict]) -> list[tuple[float, float]]:
    """[(aligned_t, cents_deviation), ...] fuer stimmhafte zugeordnete Frames, nach
    Zeit sortiert. Gemeinsamer Helfer fuer stability.py (Stabilitaet/Phrasenend-Drift)
    und glides.py (Glide-Erkennung)."""
    target_cents = hz_to_cents(note["hz"])
    series = [
        (frame["aligned_t"], hz_to_cents(frame["hz"]) - target_cents)
        for frame in attributed_frames
        if frame.get("voiced") and frame.get("hz") is not None
    ]
    series.sort(key=lambda pair: pair[0])
    return series

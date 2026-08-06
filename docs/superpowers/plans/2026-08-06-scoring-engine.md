# Bewertungs-Engine (Kernpaket) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ein neues `backend/scoring/`-Modul vergleicht die DTW-ausgerichtete Gesangskurve gegen die Zielkurve und liefert pro Note Cent-Abweichung, verfehlte-Note-Flag, Timing-Abweichung und Stabilität/Phrasenend-Drift als strukturiertes JSON über einen neuen `POST /api/score`-Endpunkt; der Mobile-Client zeigt das Ergebnis in einem neuen "4. Bewertung"-Abschnitt an.

**Architecture:** "Noten" werden direkt aus `target_curve` segmentiert (kein `MIDI_SESSIONS`-Zugriff), damit dieselbe Logik für MIDI- und Referenzaufnahme-Ziele funktioniert. Jede Note bekommt per `aligned_t` zugeordnete Gesangs-Frames, aus denen vier unabhängige Metriken berechnet werden. Der Mobile-Client folgt exakt dem in Phase 3 etablierten `align()`/`_resetAlignment()`-Muster: `score()` läuft automatisch nach `align()`.

**Tech Stack:** Python/FastAPI (`pydantic.BaseModel` für den Request-Body, sonst nur `math`/eingebaute Typen — keine neue Abhängigkeit), Flutter/Dart (bestehendes `http`-Paket).

## Global Constraints

- Kernpaket dieser Runde: Cent-Abweichung pro Note, verfehlte Zielnoten, Timing (früh/spät), Stabilität/Phrasenend-Drift. NICHT Teil: Glides, Stimmumfang, Pausen/Atemstellen.
- Grün/Gelb/Rot-Schwellen: ±15 Cent (grün) / ±50 Cent (gelb) / darüber rot — exakt aus `PLAN.md`.
- Noten-Erkennung ausschließlich aus `target_curve` segmentiert — keine Kopplung an `MIDI_SESSIONS`/`session_id`/`track_index`. Das Scoring-Modul nimmt nur `target_curve`/`sung_curve` (mit `aligned_t`) entgegen.
- `problem_tags` im Summary-JSON müssen exakt auf die bestehenden `backend/exercises/catalog.yaml`-IDs abbilden: `timingprobleme`, `absinkende_phrasenenden`, `instabile_lange_toene`, `unsaubere_einsaetze`. `haeufiges_hineingleiten` erscheint nie (Glides nicht Teil dieser Runde).
- Backend + einfache Text-/Zahlen-Anzeige in der Mobile-App (neuer Abschnitt "4. Bewertung"). Explizit NICHT die grün/gelb/rot-Kurvenfärbung im Chart selbst (spätere Phase 5).
- Neuer Endpunkt `POST /api/score`, nicht `/api/sync/align` erweitert — nimmt `target_curve`+ausgerichtete `sung_curve` als JSON-Body, kein Audio-Upload.
- Keine neuen Abhängigkeiten (FastAPI hat `pydantic` bereits als Kern-Abhängigkeit; kein neues Dart-Package).
- Deutsche Fehlermeldungen im bestehenden Stil.
- Mobile: `score()` muss exakt die Kurve verwenden, die tatsächlich ausgerichtet wurde (`targetCurve` im MIDI-Modus, `referenceRawCurve` unangetastet im Referenz-Modus — NICHT `displayedTargetCurve`, die clientseitig transponiert ist).

---

### Task 1: Noten-Segmentierung (`backend/scoring/notes.py`)

**Files:**
- Modify: `backend/config.py` (neue Konstanten anhängen, nach Zeile 37)
- Create: `backend/scoring/notes.py`
- Test: `tests/test_scoring.py` (neu)

**Interfaces:**
- Produces: `backend.scoring.notes.hz_to_cents(hz: float, ref_hz: float = 440.0) -> float`, `backend.scoring.notes.segment_target_notes(target_curve: list[dict], frame_rate_hz: float = 100.0, ...) -> list[dict]` (jede Note: `{"index": int, "start_t": float, "end_t": float, "hz": float, "midi_note": int}`), `backend.scoring.notes.attribute_sung_frames(sung_curve: list[dict], note: dict, is_last_note: bool) -> list[dict]`.

- [ ] **Step 1: Konstanten in `backend/config.py` ergänzen**

Am Dateiende (nach `PITCH_FMAX_HZ = 1050.0  # ~C6`) anfügen:

```python

# Bewertungs-Engine (Phase 4): Noten-Segmentierung aus der Zielkurve (kein
# MIDI_SESSIONS-Zugriff, siehe Design-Spec docs/superpowers/specs/2026-08-06-scoring-engine-design.md).
NOTE_SEGMENT_TOLERANCE_CENTS = 50.0
NOTE_SEGMENT_ROLLING_WINDOW_FRAMES = 30
NOTE_SEGMENT_MAX_BRIDGE_GAP_FRAMES = 15
NOTE_SEGMENT_MIN_DURATION_SECONDS = 0.12
```

- [ ] **Step 2: Test schreiben (`tests/test_scoring.py`, neu)**

```python
"""Tests fuer die Bewertungs-Engine (Phase 4, Kernpaket)."""

from __future__ import annotations

import pytest

from backend.scoring.notes import attribute_sung_frames, hz_to_cents, segment_target_notes


def _flat_curve(hz: float, n_frames: int, start_idx: int = 0, frame_rate_hz: float = 100.0) -> list[dict]:
    step = 1.0 / frame_rate_hz
    return [
        {"t": round((start_idx + i) * step, 3), "hz": hz, "midi_note": None}
        for i in range(n_frames)
    ]


def test_hz_to_cents_reference_a4_is_zero():
    assert hz_to_cents(440.0) == pytest.approx(0.0)
    assert hz_to_cents(880.0) == pytest.approx(1200.0)


def test_segment_target_notes_splits_on_pitch_jump():
    curve = _flat_curve(440.0, 100, start_idx=0) + _flat_curve(880.0, 100, start_idx=100)
    notes = segment_target_notes(curve, frame_rate_hz=100.0)
    assert len(notes) == 2
    assert notes[0]["hz"] == pytest.approx(440.0, abs=0.01)
    assert notes[1]["hz"] == pytest.approx(880.0, abs=0.01)
    assert notes[0]["start_t"] == 0.0
    assert notes[1]["start_t"] == pytest.approx(1.0, abs=0.01)


def test_segment_target_notes_bridges_short_gap():
    # 100ms Luecke (10 Frames) liegt unter dem Bridge-Limit (150ms) - bleibt EINE Note.
    step = 0.01
    curve = []
    for i in range(100):
        hz = None if 45 <= i < 55 else 440.0
        curve.append({"t": round(i * step, 3), "hz": hz, "midi_note": None})
    notes = segment_target_notes(curve, frame_rate_hz=100.0)
    assert len(notes) == 1


def test_segment_target_notes_closes_on_long_gap():
    # 300ms Luecke (30 Frames) liegt ueber dem Bridge-Limit - teilt die Note wirklich.
    step = 0.01
    curve = []
    for i in range(130):
        hz = None if 40 <= i < 70 else 440.0
        curve.append({"t": round(i * step, 3), "hz": hz, "midi_note": None})
    notes = segment_target_notes(curve, frame_rate_hz=100.0)
    assert len(notes) == 2


def test_segment_target_notes_drops_short_segments():
    # Ein 50ms "Segment" (< 120ms Mindestdauer) zwischen zwei echten Noten wird verworfen.
    curve = (
        _flat_curve(440.0, 100, start_idx=0)
        + _flat_curve(500.0, 5, start_idx=100)
        + _flat_curve(660.0, 100, start_idx=105)
    )
    notes = segment_target_notes(curve, frame_rate_hz=100.0)
    assert len(notes) == 2
    assert notes[0]["hz"] == pytest.approx(440.0, abs=0.01)
    assert notes[1]["hz"] == pytest.approx(660.0, abs=0.01)


def test_segment_target_notes_uses_midi_note_field_when_present():
    curve = [{"t": round(i * 0.01, 3), "hz": 261.626, "midi_note": 60} for i in range(100)]
    notes = segment_target_notes(curve, frame_rate_hz=100.0)
    assert len(notes) == 1
    assert notes[0]["midi_note"] == 60


def test_attribute_sung_frames_respects_note_window():
    note = {"index": 0, "start_t": 1.0, "end_t": 2.0, "hz": 440.0, "midi_note": 69}
    sung_curve = [
        {"t": 0.5, "aligned_t": 0.9},   # vor dem Fenster
        {"t": 1.2, "aligned_t": 1.2},   # im Fenster
        {"t": 1.8, "aligned_t": 1.8},   # im Fenster
        {"t": 2.1, "aligned_t": 2.1},   # nach dem Fenster (nicht letzte Note)
    ]
    attributed = attribute_sung_frames(sung_curve, note, is_last_note=False)
    assert [f["t"] for f in attributed] == [1.2, 1.8]


def test_attribute_sung_frames_last_note_is_open_ended():
    note = {"index": 0, "start_t": 1.0, "end_t": 2.0, "hz": 440.0, "midi_note": 69}
    sung_curve = [{"t": 2.5, "aligned_t": 2.5}]
    attributed = attribute_sung_frames(sung_curve, note, is_last_note=True)
    assert [f["t"] for f in attributed] == [2.5]
```

- [ ] **Step 3: Test laufen lassen, FAIL erwarten**

Run: `.venv/bin/pytest tests/test_scoring.py -v`
Expected: FAIL mit `ModuleNotFoundError`/`ImportError` für `backend.scoring.notes` (Modul existiert noch nicht).

- [ ] **Step 4: `backend/scoring/notes.py` implementieren**

```python
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
    der letzten Note nach oben offen, damit DTW-Randeffekte keine Frames verschlucken."""
    start_t = note["start_t"]
    end_t = note["end_t"]
    result = []
    for frame in sung_curve:
        aligned_t = frame.get("aligned_t")
        if aligned_t is None or aligned_t < start_t:
            continue
        if not is_last_note and aligned_t >= end_t:
            continue
        result.append(frame)
    return result
```

- [ ] **Step 5: Auch `backend/scoring/__init__.py` vorlaeufig anpassen, damit der Import funktioniert**

Ersetze den Inhalt durch:

```python
"""Bewertungs-Engine: Cent-Abweichung, verfehlte Zielnoten, Timing, Stabilitaet,
Phrasenend-Drift (Phase 4, Kernpaket). Glides, Stimmumfang, Pausen folgen spaeter.
"""

from .notes import segment_target_notes

__all__ = ["segment_target_notes"]
```

(Die weiteren Re-Exports `score_performance` etc. kommen in Task 5 dazu.)

- [ ] **Step 6: Tests laufen lassen**

Run: `.venv/bin/pytest tests/test_scoring.py -v`
Expected: alle 8 Tests PASS.

- [ ] **Step 7: Commit**

```bash
git add backend/config.py backend/scoring/notes.py backend/scoring/__init__.py tests/test_scoring.py
git commit -m "feat: add target-note segmentation for scoring engine"
```

---

### Task 2: Cent-Abweichung & verfehlte Zielnoten (`backend/scoring/pitch.py`)

**Files:**
- Modify: `backend/config.py` (neue Konstanten anhängen)
- Create: `backend/scoring/pitch.py`
- Modify: `tests/test_scoring.py` (Tests anhängen)

**Interfaces:**
- Consumes: `backend.scoring.notes.hz_to_cents` (Task 1).
- Produces: `backend.scoring.pitch.classify_cents(value: float) -> str`, `backend.scoring.pitch.compute_cents_deviation(note: dict, attributed_frames: list[dict]) -> dict | None` (`{"value": float, "classification": str}` oder `None`), `backend.scoring.pitch.compute_coverage_fraction(note: dict, attributed_frames: list[dict], frame_rate_hz: float = 100.0) -> float`, `backend.scoring.pitch.is_missed(coverage_fraction: float, cents_value: float | None) -> bool`.

- [ ] **Step 1: Konstanten in `backend/config.py` ergänzen (am Dateiende)**

```python

# Bewertungs-Engine: Cent-Abweichung & verfehlte Zielnoten.
CENTS_GREEN_THRESHOLD = 15.0
CENTS_YELLOW_THRESHOLD = 50.0
MISSED_NOTE_MIN_COVERAGE_FRACTION = 0.5
MISSED_NOTE_CENTS_THRESHOLD = 300.0
STABILITY_ONSET_TRIM_SECONDS = 0.05
```

- [ ] **Step 2: Tests an `tests/test_scoring.py` anhängen**

```python
from backend.scoring.pitch import (
    classify_cents,
    compute_cents_deviation,
    compute_coverage_fraction,
    is_missed,
)


def _sung_frame(t: float, hz: float | None, voiced: bool = True, aligned_t: float | None = None) -> dict:
    return {
        "t": t,
        "hz": hz,
        "voiced": voiced,
        "confidence": 0.9,
        "aligned_t": aligned_t if aligned_t is not None else t,
    }


def test_classify_cents_boundaries():
    assert classify_cents(14.9) == "green"
    assert classify_cents(15.0) == "green"
    assert classify_cents(15.1) == "yellow"
    assert classify_cents(-49.9) == "yellow"
    assert classify_cents(50.0) == "yellow"
    assert classify_cents(50.1) == "red"


def test_compute_cents_deviation_uses_median_not_mean():
    note = {"start_t": 0.0, "end_t": 1.2, "hz": 440.0}
    frames = [_sung_frame(round(i * 0.01, 3), 440.0) for i in range(90)]
    # Letzte 30 Frames (Phrasenende) driften stark ab - Median soll das ignorieren.
    frames += [
        _sung_frame(round((90 + i) * 0.01, 3), 440.0 * 2 ** (-100 * (i / 30) / 1200))
        for i in range(30)
    ]
    result = compute_cents_deviation(note, frames)
    assert result is not None
    assert abs(result["value"]) < 5


def test_compute_cents_deviation_none_without_voiced_frames():
    note = {"start_t": 0.0, "end_t": 1.0, "hz": 440.0}
    frames = [_sung_frame(0.5, None, voiced=False)]
    assert compute_cents_deviation(note, frames) is None


def test_compute_coverage_fraction_full_coverage():
    note = {"start_t": 0.0, "end_t": 1.0}
    frames = [_sung_frame(round(i * 0.01, 3), 440.0) for i in range(100)]
    assert compute_coverage_fraction(note, frames) == pytest.approx(1.0, abs=0.02)


def test_compute_coverage_fraction_no_voiced_frames():
    note = {"start_t": 0.0, "end_t": 1.0}
    assert compute_coverage_fraction(note, []) == 0.0


def test_is_missed_flags_low_coverage():
    assert is_missed(coverage_fraction=0.3, cents_value=0.0) is True
    assert is_missed(coverage_fraction=0.8, cents_value=0.0) is False


def test_is_missed_flags_gross_pitch_error():
    assert is_missed(coverage_fraction=1.0, cents_value=500.0) is True
    assert is_missed(coverage_fraction=1.0, cents_value=100.0) is False
```

- [ ] **Step 3: Test laufen lassen, FAIL erwarten**

Run: `.venv/bin/pytest tests/test_scoring.py -v -k "cents or coverage or missed"`
Expected: FAIL mit `ImportError` für `backend.scoring.pitch`.

- [ ] **Step 4: `backend/scoring/pitch.py` implementieren**

```python
"""Cent-Abweichung & verfehlte Zielnoten (Phase 4)."""

from __future__ import annotations

from backend.config import (
    CENTS_GREEN_THRESHOLD,
    CENTS_YELLOW_THRESHOLD,
    MISSED_NOTE_CENTS_THRESHOLD,
    MISSED_NOTE_MIN_COVERAGE_FRACTION,
    STABILITY_ONSET_TRIM_SECONDS,
)
from backend.scoring.notes import hz_to_cents


def classify_cents(value: float) -> str:
    magnitude = abs(value)
    if magnitude <= CENTS_GREEN_THRESHOLD:
        return "green"
    if magnitude <= CENTS_YELLOW_THRESHOLD:
        return "yellow"
    return "red"


def _voiced_deviations(note: dict, attributed_frames: list[dict]) -> list[float]:
    onset_cutoff = note["start_t"] + STABILITY_ONSET_TRIM_SECONDS
    target_cents = hz_to_cents(note["hz"])
    deviations = []
    for frame in attributed_frames:
        if not frame.get("voiced") or frame.get("hz") is None:
            continue
        if frame["aligned_t"] < onset_cutoff:
            continue
        deviations.append(hz_to_cents(frame["hz"]) - target_cents)
    return deviations


def compute_cents_deviation(note: dict, attributed_frames: list[dict]) -> dict | None:
    """{'value': float, 'classification': str} oder None, wenn keine stimmhaften
    Frames zugeordnet werden konnten (dann greift stattdessen is_missed())."""
    deviations = sorted(_voiced_deviations(note, attributed_frames))
    if not deviations:
        return None
    median_value = deviations[len(deviations) // 2]
    return {"value": round(median_value, 1), "classification": classify_cents(median_value)}


def compute_coverage_fraction(note: dict, attributed_frames: list[dict], frame_rate_hz: float = 100.0) -> float:
    """Anteil der Ziel-Zeitraster-Buckets im Notenfenster, die von mindestens einem
    stimmhaften zugeordneten Frame abgedeckt sind. Dedupliziert nach Bucket (nicht
    nach Roh-Frame-Anzahl), da DTW mehrere Gesangs-Frames auf denselben Ziel-Frame
    abbilden kann."""
    step = 1.0 / frame_rate_hz
    expected_buckets = max(1, round((note["end_t"] - note["start_t"]) / step))
    covered_buckets: set[int] = set()
    for frame in attributed_frames:
        if not frame.get("voiced") or frame.get("hz") is None:
            continue
        bucket = round((frame["aligned_t"] - note["start_t"]) / step)
        covered_buckets.add(bucket)
    return min(1.0, len(covered_buckets) / expected_buckets)


def is_missed(coverage_fraction: float, cents_value: float | None) -> bool:
    if coverage_fraction < MISSED_NOTE_MIN_COVERAGE_FRACTION:
        return True
    if cents_value is not None and abs(cents_value) > MISSED_NOTE_CENTS_THRESHOLD:
        return True
    return False
```

- [ ] **Step 5: Tests laufen lassen**

Run: `.venv/bin/pytest tests/test_scoring.py -v`
Expected: alle Tests (8 aus Task 1 + 7 aus diesem Task) PASS.

- [ ] **Step 6: Commit**

```bash
git add backend/config.py backend/scoring/pitch.py tests/test_scoring.py
git commit -m "feat: add cents-deviation and missed-note scoring"
```

---

### Task 3: Timing / Einsatzabweichung (`backend/scoring/timing.py`)

**Files:**
- Modify: `backend/config.py` (neue Konstanten anhängen)
- Create: `backend/scoring/timing.py`
- Modify: `tests/test_scoring.py` (Tests anhängen)

**Interfaces:**
- Produces: `backend.scoring.timing.classify_timing(deviation_ms: float) -> str`, `backend.scoring.timing.compute_onset_deviation_ms(sung_curve: list[dict], note: dict, window_frames: int = 5) -> float | None`.

- [ ] **Step 1: Konstanten in `backend/config.py` ergänzen (am Dateiende)**

```python

# Bewertungs-Engine: Timing (fruehe/spaete Einsaetze).
TIMING_ONSET_WINDOW_FRAMES = 5
TIMING_OK_THRESHOLD_MS = 60.0
```

- [ ] **Step 2: Tests an `tests/test_scoring.py` anhängen**

```python
from backend.scoring.timing import classify_timing, compute_onset_deviation_ms


def test_classify_timing_boundaries():
    assert classify_timing(60.0) == "on_time"
    assert classify_timing(60.1) == "too_early"
    assert classify_timing(-60.0) == "on_time"
    assert classify_timing(-60.1) == "too_late"


def test_compute_onset_deviation_ms_recovers_offset():
    # Zielnote beginnt bei t=2.0s; die "gesungene" Onset-Umgebung liegt bei
    # aligned_t~2.0, aber raw t~1.85 (150ms zu frueh gesungen) - deviation_ms
    # muss ~+150ms betragen (aligned_t - t).
    note = {"start_t": 2.0, "end_t": 3.0}
    sung_curve = [
        {"t": round(1.85 + i * 0.01, 3), "hz": 391.995, "voiced": True,
         "aligned_t": round(2.0 + i * 0.01, 3)}
        for i in range(10)
    ]
    deviation = compute_onset_deviation_ms(sung_curve, note)
    assert deviation is not None
    assert 100 <= deviation <= 200


def test_compute_onset_deviation_ms_none_without_voiced_frames():
    note = {"start_t": 2.0, "end_t": 3.0}
    assert compute_onset_deviation_ms([], note) is None
```

- [ ] **Step 3: Test laufen lassen, FAIL erwarten**

Run: `.venv/bin/pytest tests/test_scoring.py -v -k timing`
Expected: FAIL mit `ImportError` für `backend.scoring.timing`.

- [ ] **Step 4: `backend/scoring/timing.py` implementieren**

```python
"""Timing / Einsatzabweichung (Phase 4)."""

from __future__ import annotations

from backend.config import TIMING_OK_THRESHOLD_MS, TIMING_ONSET_WINDOW_FRAMES


def classify_timing(deviation_ms: float) -> str:
    if deviation_ms > TIMING_OK_THRESHOLD_MS:
        return "too_early"
    if deviation_ms < -TIMING_OK_THRESHOLD_MS:
        return "too_late"
    return "on_time"


def compute_onset_deviation_ms(
    sung_curve: list[dict], note: dict, window_frames: int = TIMING_ONSET_WINDOW_FRAMES,
) -> float | None:
    """Median von (aligned_t - t) * 1000 der `window_frames` stimmhaften Gesangs-
    Frames, deren aligned_t am naechsten am Notenanfang liegt. Sucht ueber die
    GESAMTE sung_curve (nicht nur die dieser Note zugeordneten Frames), da der
    naechste stimmhafte Einsatz auch knapp ausserhalb des Zuordnungsfensters
    liegen kann (z.B. bei einer zu frueh gesungenen Note)."""
    voiced = [f for f in sung_curve if f.get("voiced") and f.get("aligned_t") is not None]
    if not voiced:
        return None
    voiced.sort(key=lambda f: abs(f["aligned_t"] - note["start_t"]))
    nearest = voiced[:window_frames]
    deltas = sorted((f["aligned_t"] - f["t"]) * 1000.0 for f in nearest)
    return deltas[len(deltas) // 2]
```

- [ ] **Step 5: Tests laufen lassen**

Run: `.venv/bin/pytest tests/test_scoring.py -v`
Expected: alle Tests (15 aus Task 1+2 + 3 aus diesem Task) PASS.

- [ ] **Step 6: Commit**

```bash
git add backend/config.py backend/scoring/timing.py tests/test_scoring.py
git commit -m "feat: add onset-timing scoring"
```

---

### Task 4: Stabilität & Phrasenend-Drift (`backend/scoring/stability.py`)

**Files:**
- Modify: `backend/config.py` (neue Konstanten anhängen)
- Create: `backend/scoring/stability.py`
- Modify: `tests/test_scoring.py` (Tests anhängen)

**Interfaces:**
- Consumes: `backend.scoring.notes.hz_to_cents` (Task 1).
- Produces: `backend.scoring.stability.is_held_note(note: dict) -> bool`, `backend.scoring.stability.compute_stability(note: dict, attributed_frames: list[dict]) -> dict` (`{"applicable": bool, "mad_cents": float | None, "flag": bool}`), `backend.scoring.stability.compute_phrase_end_drift(note: dict, attributed_frames: list[dict]) -> dict` (`{"applicable": bool, "drift_cents": float | None, "flag": bool, "direction": str | None}`).

- [ ] **Step 1: Konstanten in `backend/config.py` ergänzen (am Dateiende)**

```python

# Bewertungs-Engine: Stabilitaet & Phrasenend-Drift bei gehaltenen Toenen.
HELD_NOTE_MIN_DURATION_SECONDS = 0.6
STABILITY_MAD_THRESHOLD_CENTS = 25.0
DRIFT_TAIL_SECONDS = 0.3
DRIFT_FLAG_THRESHOLD_CENTS = 30.0
```

- [ ] **Step 2: Tests an `tests/test_scoring.py` anhängen**

```python
from backend.scoring.stability import compute_phrase_end_drift, compute_stability, is_held_note


def test_is_held_note():
    assert is_held_note({"start_t": 0.0, "end_t": 0.6}) is True
    assert is_held_note({"start_t": 0.0, "end_t": 0.59}) is False


def test_compute_stability_not_applicable_for_short_note():
    note = {"start_t": 0.0, "end_t": 0.3, "hz": 440.0}
    result = compute_stability(note, [])
    assert result["applicable"] is False


def test_compute_phrase_end_drift_flags_tail_drop():
    note = {"start_t": 3.0, "end_t": 4.2, "hz": 329.628}
    frames = [
        _sung_frame(round(3.0 + i * 0.01, 3), 329.628, aligned_t=round(3.0 + i * 0.01, 3))
        for i in range(90)
    ]
    frames += [
        _sung_frame(
            round(3.9 + i * 0.01, 3),
            329.628 * 2 ** (-100 * (i / 30) / 1200),
            aligned_t=round(3.9 + i * 0.01, 3),
        )
        for i in range(30)
    ]
    result = compute_phrase_end_drift(note, frames)
    assert result["applicable"] is True
    assert result["flag"] is True
    assert result["direction"] == "down"


def test_compute_stability_and_drift_ignore_constant_offset():
    # Konstante -40 Cent ueber die ganze Note - kein Drift (Hauptteil und Ende
    # sind gleich weit daneben), auch keine Instabilitaet (Streuung im Hauptteil
    # bleibt klein).
    note = {"start_t": 1.0, "end_t": 2.0, "hz": 329.628}
    offset_hz = 329.628 * 2 ** (-40 / 1200)
    frames = [
        _sung_frame(round(1.0 + i * 0.01, 3), offset_hz, aligned_t=round(1.0 + i * 0.01, 3))
        for i in range(100)
    ]
    stability = compute_stability(note, frames)
    drift = compute_phrase_end_drift(note, frames)
    assert stability["flag"] is False
    assert drift["flag"] is False
```

- [ ] **Step 3: Test laufen lassen, FAIL erwarten**

Run: `.venv/bin/pytest tests/test_scoring.py -v -k "held or stability or drift"`
Expected: FAIL mit `ImportError` für `backend.scoring.stability`.

- [ ] **Step 4: `backend/scoring/stability.py` implementieren**

```python
"""Stabilitaet & Phrasenend-Drift bei gehaltenen Toenen (Phase 4).

Zwei DISJUNKTE Zeitfenster (Hauptteil ohne die letzten DRIFT_TAIL_SECONDS fuer
Stabilitaet, ausschliesslich die letzten DRIFT_TAIL_SECONDS fuer Drift) statt
eines gemeinsamen Fensters: das ist der Grund, warum eine konstant falsch
gesungene Note (durchgehend z.B. -40 Cent, aber kein Drift) korrekt von einer am
Ende absackenden Note (stabiler Hauptteil, aber Drift im letzten Viertel)
unterschieden wird - mit einem gemeinsamen Fenster wuerde die zweite Note faelsch-
licherweise auch als "instabil" gelten, weil die Streuung ueber die ganze Note
durch den Drift-Anteil aufgeblaeht wuerde.
"""

from __future__ import annotations

from backend.config import (
    DRIFT_FLAG_THRESHOLD_CENTS,
    DRIFT_TAIL_SECONDS,
    HELD_NOTE_MIN_DURATION_SECONDS,
    STABILITY_MAD_THRESHOLD_CENTS,
    STABILITY_ONSET_TRIM_SECONDS,
)
from backend.scoring.notes import hz_to_cents

_NOT_APPLICABLE_STABILITY = {"applicable": False, "mad_cents": None, "flag": False}
_NOT_APPLICABLE_DRIFT = {"applicable": False, "drift_cents": None, "flag": False, "direction": None}


def is_held_note(note: dict) -> bool:
    return (note["end_t"] - note["start_t"]) >= HELD_NOTE_MIN_DURATION_SECONDS


def _cents_series(note: dict, attributed_frames: list[dict]) -> list[tuple[float, float]]:
    """[(aligned_t, cents_deviation), ...] fuer stimmhafte zugeordnete Frames, nach
    Zeit sortiert."""
    target_cents = hz_to_cents(note["hz"])
    series = [
        (frame["aligned_t"], hz_to_cents(frame["hz"]) - target_cents)
        for frame in attributed_frames
        if frame.get("voiced") and frame.get("hz") is not None
    ]
    series.sort(key=lambda pair: pair[0])
    return series


def compute_stability(note: dict, attributed_frames: list[dict]) -> dict:
    if not is_held_note(note):
        return dict(_NOT_APPLICABLE_STABILITY)

    body_start = note["start_t"] + STABILITY_ONSET_TRIM_SECONDS
    body_end = note["end_t"] - DRIFT_TAIL_SECONDS
    body_values = sorted(
        c for t, c in _cents_series(note, attributed_frames) if body_start <= t < body_end
    )
    if not body_values:
        return dict(_NOT_APPLICABLE_STABILITY)

    median_value = body_values[len(body_values) // 2]
    abs_deviations = sorted(abs(v - median_value) for v in body_values)
    mad = abs_deviations[len(abs_deviations) // 2]
    return {
        "applicable": True,
        "mad_cents": round(mad, 1),
        "flag": mad > STABILITY_MAD_THRESHOLD_CENTS,
    }


def compute_phrase_end_drift(note: dict, attributed_frames: list[dict]) -> dict:
    if not is_held_note(note):
        return dict(_NOT_APPLICABLE_DRIFT)

    body_start = note["start_t"] + STABILITY_ONSET_TRIM_SECONDS
    body_end = note["end_t"] - DRIFT_TAIL_SECONDS
    series = _cents_series(note, attributed_frames)
    body_values = sorted(c for t, c in series if body_start <= t < body_end)
    tail_values = sorted(c for t, c in series if t >= body_end)
    if not body_values or not tail_values:
        return dict(_NOT_APPLICABLE_DRIFT)

    body_median = body_values[len(body_values) // 2]
    tail_median = tail_values[len(tail_values) // 2]
    drift = tail_median - body_median
    flag = abs(drift) > DRIFT_FLAG_THRESHOLD_CENTS
    direction = ("down" if drift < 0 else "up") if flag else None
    return {"applicable": True, "drift_cents": round(drift, 1), "flag": flag, "direction": direction}
```

- [ ] **Step 5: Tests laufen lassen**

Run: `.venv/bin/pytest tests/test_scoring.py -v`
Expected: alle Tests (18 aus Task 1-3 + 4 aus diesem Task) PASS.

- [ ] **Step 6: Commit**

```bash
git add backend/config.py backend/scoring/stability.py tests/test_scoring.py
git commit -m "feat: add held-note stability and phrase-end-drift scoring"
```

---

### Task 5: Orchestrator (`backend/scoring/score.py`)

**Files:**
- Create: `backend/scoring/score.py`
- Modify: `backend/scoring/__init__.py`
- Modify: `tests/test_scoring.py` (Tests anhängen)

**Interfaces:**
- Consumes: alle Funktionen aus Task 1-4 (`segment_target_notes`, `attribute_sung_frames`, `compute_cents_deviation`, `compute_coverage_fraction`, `is_missed`, `compute_onset_deviation_ms`, `classify_timing`, `compute_stability`, `compute_phrase_end_drift`, `is_held_note`).
- Produces: `backend.scoring.score.score_performance(target_curve: list[dict], sung_curve: list[dict], frame_rate_hz: float = 100.0) -> dict` (siehe JSON-Schema in der Design-Spec) und `backend.scoring.score_performance`/`backend.scoring.segment_target_notes` als Modul-Re-Exports.

- [ ] **Step 1: Tests an `tests/test_scoring.py` anhängen**

```python
from backend.scoring import score_performance


def test_score_performance_raises_without_aligned_t():
    target_curve = [{"t": 0.0, "hz": 440.0, "midi_note": 69}]
    sung_curve = [{"t": 0.0, "hz": 440.0, "voiced": True, "confidence": 0.9}]  # kein aligned_t
    with pytest.raises(ValueError):
        score_performance(target_curve, sung_curve)


def test_score_performance_empty_curves_returns_empty_result():
    result = score_performance([], [])
    assert result["notes"] == []
    assert result["summary"]["note_count"] == 0
    assert result["summary"]["problem_tags"] == []


def test_score_performance_single_correct_note():
    target_curve = _flat_curve(440.0, 100)
    sung_curve = [
        {"t": round(i * 0.01, 3), "hz": 440.0, "voiced": True, "confidence": 0.9,
         "aligned_t": round(i * 0.01, 3)}
        for i in range(100)
    ]
    result = score_performance(target_curve, sung_curve)
    assert len(result["notes"]) == 1
    note = result["notes"][0]
    assert note["missed"] is False
    assert note["cents_deviation"]["classification"] == "green"
    assert note["timing"]["classification"] == "on_time"
    assert result["summary"]["cents_green"] == 1
    assert result["summary"]["problem_tags"] == []
```

- [ ] **Step 2: Test laufen lassen, FAIL erwarten**

Run: `.venv/bin/pytest tests/test_scoring.py -v -k score_performance`
Expected: FAIL mit `ImportError` für `score_performance` aus `backend.scoring`.

- [ ] **Step 3: `backend/scoring/score.py` implementieren**

```python
"""Bewertungs-Engine Orchestrator (Phase 4): fasst Noten-Segmentierung und alle
vier Kernpaket-Metriken zu einem strukturierten Ergebnis zusammen."""

from __future__ import annotations

from backend.scoring.notes import attribute_sung_frames, segment_target_notes
from backend.scoring.pitch import compute_cents_deviation, compute_coverage_fraction, is_missed
from backend.scoring.stability import compute_phrase_end_drift, compute_stability, is_held_note
from backend.scoring.timing import classify_timing, compute_onset_deviation_ms

_PROBLEM_TAG_TIMING = "timingprobleme"
_PROBLEM_TAG_DRIFT = "absinkende_phrasenenden"
_PROBLEM_TAG_STABILITY = "instabile_lange_toene"
_PROBLEM_TAG_MISSED = "unsaubere_einsaetze"


def score_performance(
    target_curve: list[dict], sung_curve: list[dict], frame_rate_hz: float = 100.0,
) -> dict:
    if sung_curve and any("aligned_t" not in frame for frame in sung_curve):
        raise ValueError(
            "sung_curve-Frames ohne 'aligned_t' - bitte zuerst align_curves() aufrufen."
        )

    target_notes = segment_target_notes(target_curve, frame_rate_hz=frame_rate_hz)

    notes: list[dict] = []
    problem_tags: set[str] = set()
    cents_green = cents_yellow = cents_red = 0
    missed_count = timing_flagged = stability_flagged = drift_flagged = 0

    for i, note in enumerate(target_notes):
        is_last = i == len(target_notes) - 1
        attributed = attribute_sung_frames(sung_curve, note, is_last)

        coverage = compute_coverage_fraction(note, attributed, frame_rate_hz)
        cents = compute_cents_deviation(note, attributed)
        cents_value = cents["value"] if cents else None
        missed = is_missed(coverage, cents_value)

        onset_ms = compute_onset_deviation_ms(sung_curve, note)
        timing_classification = classify_timing(onset_ms) if onset_ms is not None else "on_time"

        stability = compute_stability(note, attributed)
        drift = compute_phrase_end_drift(note, attributed)

        if missed or (cents and cents["classification"] == "red"):
            problem_tags.add(_PROBLEM_TAG_MISSED)
        if timing_classification != "on_time":
            problem_tags.add(_PROBLEM_TAG_TIMING)
            timing_flagged += 1
        if stability["flag"]:
            problem_tags.add(_PROBLEM_TAG_STABILITY)
            stability_flagged += 1
        if drift["flag"]:
            problem_tags.add(_PROBLEM_TAG_DRIFT)
            drift_flagged += 1

        if missed:
            missed_count += 1
        elif cents:
            if cents["classification"] == "green":
                cents_green += 1
            elif cents["classification"] == "yellow":
                cents_yellow += 1
            else:
                cents_red += 1

        notes.append({
            "index": note["index"],
            "start_t": note["start_t"],
            "end_t": note["end_t"],
            "target_hz": note["hz"],
            "target_midi_note": note["midi_note"],
            "missed": missed,
            "coverage_fraction": round(coverage, 3),
            "cents_deviation": cents or {"value": None, "classification": "red"},
            "timing": {
                "deviation_ms": round(onset_ms, 1) if onset_ms is not None else None,
                "classification": timing_classification,
            },
            "held": is_held_note(note),
            "stability": stability,
            "phrase_end_drift": drift,
        })

    note_count = len(notes)
    penalty = (
        missed_count * 100
        + cents_yellow * 20 + cents_red * 45
        + timing_flagged * 15 + stability_flagged * 10 + drift_flagged * 10
    )
    overall_score = max(0.0, 100.0 - (penalty / note_count)) if note_count else 0.0

    return {
        "notes": notes,
        "summary": {
            "note_count": note_count,
            "missed_count": missed_count,
            "cents_green": cents_green,
            "cents_yellow": cents_yellow,
            "cents_red": cents_red,
            "timing_flagged_count": timing_flagged,
            "stability_flagged_count": stability_flagged,
            "phrase_end_drift_flagged_count": drift_flagged,
            "overall_score": round(overall_score, 1),
            "problem_tags": sorted(problem_tags),
        },
    }
```

- [ ] **Step 4: `backend/scoring/__init__.py` erweitern**

```python
"""Bewertungs-Engine: Cent-Abweichung, verfehlte Zielnoten, Timing, Stabilitaet,
Phrasenend-Drift (Phase 4, Kernpaket). Glides, Stimmumfang, Pausen folgen spaeter.
"""

from .notes import segment_target_notes
from .score import score_performance

__all__ = ["score_performance", "segment_target_notes"]
```

- [ ] **Step 5: Tests laufen lassen**

Run: `.venv/bin/pytest tests/test_scoring.py -v`
Expected: alle Tests (22 aus Task 1-4 + 3 aus diesem Task) PASS.

- [ ] **Step 6: Commit**

```bash
git add backend/scoring/score.py backend/scoring/__init__.py tests/test_scoring.py
git commit -m "feat: add scoring orchestrator (score_performance)"
```

---

### Task 6: End-to-End-Validierung mit der bestehenden Fixture

**Files:**
- Create: `tests/test_e2e_phase4.py`

**Interfaces:**
- Consumes: `backend.audio_io.load_audio_signal`, `backend.midi_analysis.{load_midi, track_pitch_curve}`, `backend.pitch_detection.pitch_curve_from_signal`, `backend.sync.{align_curves, onset_envelope_from_midi_track, onset_envelope_from_signal}` (alle bestehend), `backend.scoring.score_performance` (Task 5), `tests.fixtures.generate_fixtures.generate` (bestehend).
- Produces: nichts (reiner Validierungstest).

- [ ] **Step 1: Test schreiben**

```python
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


if __name__ == "__main__":
    test_scoring_matches_fixture_expectations()
    print("Phase-4-Scoring-Test erfolgreich.")
```

- [ ] **Step 2: Test ausführen**

Run: `.venv/bin/pytest tests/test_e2e_phase4.py -v`

Erwartung: PASS. Dieser Test kombiniert die auf synthetischen Zahlen validierte Logik aus Task 1-5 mit echter, per `librosa.pyin`/`onset_strength` verarbeiteter Audio-Fixture - ein Fehlschlag beim ersten Lauf ist möglich (analog zu Phase 3s Task 4). **Falls FAIL:** Füge vor den Assertions temporär `print([(n["index"], n["cents_deviation"], n["timing"], n["phrase_end_drift"]) for n in notes])` ein, um die tatsächlichen Werte zu sehen, und passe Toleranzen/Konstanten (`CENTS_YELLOW_THRESHOLD`, `DRIFT_FLAG_THRESHOLD_CENTS`, `NOTE_SEGMENT_TOLERANCE_CENTS` etc.) auf Basis der beobachteten Werte an - die Assertions müssen dabei weiterhin trennscharf zwischen den fünf unterschiedlichen Noten-Situationen unterscheiden, nicht einfach aufgeweitet werden, bis der Test zufällig grün ist. Entferne den Debug-`print` wieder, sobald die Werte stimmen.

- [ ] **Step 3: Commit**

```bash
git add tests/test_e2e_phase4.py
git commit -m "test: add Phase 4 end-to-end scoring validation"
```

---

### Task 7: Backend-Endpunkt `POST /api/score`

**Files:**
- Modify: `backend/config.py` (neue Konstante anhängen)
- Modify: `backend/api/routes.py`

**Interfaces:**
- Consumes: `backend.scoring.score_performance` (Task 5).
- Produces: Route `POST /api/score`, Response-Form `{"score": {...wie score_performance()...}}`.

Kein automatisierter HTTP-Test (Projektkonvention, siehe DTW-Plan: keine `TestClient`-Tests im Repo). Verifikation manuell über den laufenden Server.

- [ ] **Step 1: Konstante in `backend/config.py` ergänzen (am Dateiende)**

```python

# Groessenschutz fuer POST /api/score (kein Audio-Upload -> MAX_AUDIO_SECONDS greift
# hier nicht automatisch, da ein Client theoretisch ein ueberlanges JSON-Array direkt
# posten koennte, ohne ueber /api/audio/analyze bzw. /api/sync/align gegangen zu sein).
MAX_SCORE_CURVE_FRAMES = 20000  # ~200s bei 100Hz, grosszuegig ueber MAX_AUDIO_SECONDS
```

- [ ] **Step 2: Imports in `backend/api/routes.py` ergänzen**

Ersetze die bestehenden Importzeilen (`backend/api/routes.py:8-26`) durch:

```python
from __future__ import annotations

import uuid

from fastapi import APIRouter, Depends, File, Form, HTTPException, Request, UploadFile
from pydantic import BaseModel

from backend.audio_io import AudioDecodeError, load_audio_signal
from backend.config import MAX_AUDIO_SECONDS, MAX_SCORE_CURVE_FRAMES, PITCH_FMAX_HZ, PITCH_FMIN_HZ
from backend.midi_analysis import list_track_candidates, load_midi, track_pitch_curve
from backend.pitch_detection import PitchAnalysisError, analyze_pitch, pitch_curve_from_signal
from backend.scoring import score_performance
from backend.sync import (
    align_curves,
    duration_ratio_exceeds_limit,
    onset_envelope_from_midi_track,
    onset_envelope_from_signal,
)

from .rate_limit import enforce_upload_rate_limit
from .state import MIDI_SESSIONS
```

(Ergänzt `Form` bereits vorhandene Imports um `BaseModel` aus `pydantic`, `MAX_SCORE_CURVE_FRAMES` aus `backend.config`, `score_performance` aus `backend.scoring`.)

- [ ] **Step 3: Neue Route am Dateiende ergänzen (nach `sync_align`, `backend/api/routes.py:117-183`)**

```python
class ScoreRequest(BaseModel):
    target_curve: list[dict]
    sung_curve: list[dict]  # muss die AUSGERICHTETE Kurve sein (aligned_t vorhanden)


@router.post("/score")
def score(body: ScoreRequest) -> dict:
    if len(body.target_curve) > MAX_SCORE_CURVE_FRAMES or len(body.sung_curve) > MAX_SCORE_CURVE_FRAMES:
        raise HTTPException(status_code=413, detail="Kurve ist unerwartet lang.")
    try:
        result = score_performance(body.target_curve, body.sung_curve)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return {"score": result}
```

- [ ] **Step 4: Bestehende Tests erneut laufen lassen (Regressionsschutz)**

Run: `.venv/bin/pytest tests/ -v`
Expected: alle Tests weiterhin PASS.

- [ ] **Step 5: Manuelle Verifikation über den laufenden Server**

```bash
.venv/bin/python run.py &
sleep 2

SESSION_ID=$(curl -s -F "file=@tests/fixtures/test_reference.mid" http://127.0.0.1:8000/api/midi/upload | python3 -c "import json,sys; print(json.load(sys.stdin)['session_id'])")

ALIGN_JSON=$(curl -s -F "sung_audio=@tests/fixtures/test_vocal.wav" \
     -F "session_id=$SESSION_ID" -F "track_index=0" \
     http://127.0.0.1:8000/api/sync/align)

echo "$ALIGN_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(json.dumps({'target_curve': data['target_curve'], 'sung_curve': data['sung_curve']}))
" > /tmp/score_request.json

curl -s -X POST -H "Content-Type: application/json" \
     -d @/tmp/score_request.json \
     http://127.0.0.1:8000/api/score | python3 -m json.tool | head -60

kill %1
```

Erwartung: HTTP 200, JSON mit `score.notes` (5 Einträge) und `score.summary` (u.a. `problem_tags: ["absinkende_phrasenenden", "timingprobleme"]`).

- [ ] **Step 6: Commit**

```bash
git add backend/config.py backend/api/routes.py
git commit -m "feat: add POST /api/score endpoint"
```

---

### Task 8: Mobile-Modelle & API-Layer (`ScoreResult`, `ApiClient.postJson`, `ScoreApi`)

**Files:**
- Modify: `mobile/lib/models/target_point.dart`
- Modify: `mobile/lib/models/sung_point.dart`
- Create: `mobile/lib/models/score_result.dart`
- Modify: `mobile/lib/api/api_client.dart`
- Create: `mobile/lib/api/score_api.dart`

**Interfaces:**
- Produces: `TargetPoint.toJson() -> Map<String, dynamic>`, `SungPoint.toJson() -> Map<String, dynamic>`, `ScoreNote`/`ScoreSummary`/`ScoreResult` (alle mit `fromJson`-Factory, in `score_result.dart`), `ApiClient.postJson(String path, Map<String, dynamic> body) -> Future<Map<String, dynamic>>`, `ScoreApi.score(List<Map<String, dynamic>> targetCurveJson, List<SungPoint> alignedSungCurve) -> Future<ScoreResult>`.

Kein eigener Test-Task (Projektkonvention: `MidiApi`/`AudioApi`/`SyncApi` haben ebenfalls keine direkten Unit-Tests) — Abdeckung erfolgt transitiv über Task 9s `session_state_test.dart`.

- [ ] **Step 1: `mobile/lib/models/target_point.dart` — `toJson()` ergänzen**

Ersetze den Dateiinhalt durch:

```dart
/// Ein Punkt der MIDI-Zielkurve, wie sie track_pitch_curve() in
/// backend/midi_analysis/parser.py liefert. hz/midiNote sind null waehrend Pausen.
class TargetPoint {
  final double t;
  final double? hz;
  final int? midiNote;

  const TargetPoint({required this.t, required this.hz, required this.midiNote});

  factory TargetPoint.fromJson(Map<String, dynamic> json) {
    return TargetPoint(
      t: (json['t'] as num).toDouble(),
      hz: (json['hz'] as num?)?.toDouble(),
      midiNote: json['midi_note'] as int?,
    );
  }

  Map<String, dynamic> toJson() => {'t': t, 'hz': hz, 'midi_note': midiNote};
}
```

- [ ] **Step 2: `mobile/lib/models/sung_point.dart` — `toJson()` ergänzen**

Ersetze den Dateiinhalt durch:

```dart
/// Ein Punkt der gesungenen Pitch-Kurve, wie sie analyze_pitch() in
/// backend/pitch_detection/pyin.py liefert. hz ist null bei unstimmhaften/stillen
/// Abschnitten (Pausen, Atmen, Konsonanten) - dort gilt voiced == false.
///
/// alignedT ist null, bis /api/sync/align erfolgreich war - dann die per DTW
/// ermittelte Zielzeit dieses Frames (siehe backend/sync/align.py).
class SungPoint {
  final double t;
  final double? hz;
  final bool voiced;
  final double confidence;
  final double? alignedT;

  const SungPoint({
    required this.t,
    required this.hz,
    required this.voiced,
    required this.confidence,
    this.alignedT,
  });

  factory SungPoint.fromJson(Map<String, dynamic> json) {
    return SungPoint(
      t: (json['t'] as num).toDouble(),
      hz: (json['hz'] as num?)?.toDouble(),
      voiced: json['voiced'] as bool,
      confidence: (json['confidence'] as num).toDouble(),
      alignedT: (json['aligned_t'] as num?)?.toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
        't': t,
        'hz': hz,
        'voiced': voiced,
        'confidence': confidence,
        'aligned_t': alignedT,
      };
}
```

- [ ] **Step 3: `mobile/lib/models/score_result.dart` anlegen**

```dart
/// Ergebnis von POST /api/score (backend/scoring/score.py::score_performance),
/// siehe docs/superpowers/specs/2026-08-06-scoring-engine-design.md fuer das
/// vollstaendige JSON-Schema.
class ScoreNote {
  final int index;
  final double startT;
  final double endT;
  final double? targetHz;
  final int? targetMidiNote;
  final bool missed;
  final double coverageFraction;
  final double? centsValue;
  final String centsClassification;
  final double? timingDeviationMs;
  final String timingClassification;
  final bool held;
  final bool stabilityApplicable;
  final double? stabilityMadCents;
  final bool stabilityFlag;
  final bool driftApplicable;
  final double? driftCents;
  final bool phraseEndDriftFlag;
  final String? driftDirection;

  const ScoreNote({
    required this.index,
    required this.startT,
    required this.endT,
    required this.targetHz,
    required this.targetMidiNote,
    required this.missed,
    required this.coverageFraction,
    required this.centsValue,
    required this.centsClassification,
    required this.timingDeviationMs,
    required this.timingClassification,
    required this.held,
    required this.stabilityApplicable,
    required this.stabilityMadCents,
    required this.stabilityFlag,
    required this.driftApplicable,
    required this.driftCents,
    required this.phraseEndDriftFlag,
    required this.driftDirection,
  });

  factory ScoreNote.fromJson(Map<String, dynamic> json) {
    final cents = json['cents_deviation'] as Map<String, dynamic>;
    final timing = json['timing'] as Map<String, dynamic>;
    final stability = json['stability'] as Map<String, dynamic>;
    final drift = json['phrase_end_drift'] as Map<String, dynamic>;
    return ScoreNote(
      index: json['index'] as int,
      startT: (json['start_t'] as num).toDouble(),
      endT: (json['end_t'] as num).toDouble(),
      targetHz: (json['target_hz'] as num?)?.toDouble(),
      targetMidiNote: json['target_midi_note'] as int?,
      missed: json['missed'] as bool,
      coverageFraction: (json['coverage_fraction'] as num).toDouble(),
      centsValue: (cents['value'] as num?)?.toDouble(),
      centsClassification: cents['classification'] as String,
      timingDeviationMs: (timing['deviation_ms'] as num?)?.toDouble(),
      timingClassification: timing['classification'] as String,
      held: json['held'] as bool,
      stabilityApplicable: stability['applicable'] as bool,
      stabilityMadCents: (stability['mad_cents'] as num?)?.toDouble(),
      stabilityFlag: stability['flag'] as bool,
      driftApplicable: drift['applicable'] as bool,
      driftCents: (drift['drift_cents'] as num?)?.toDouble(),
      phraseEndDriftFlag: drift['flag'] as bool,
      driftDirection: drift['direction'] as String?,
    );
  }
}

class ScoreSummary {
  final int noteCount;
  final int missedCount;
  final int centsGreen;
  final int centsYellow;
  final int centsRed;
  final int timingFlaggedCount;
  final int stabilityFlaggedCount;
  final int phraseEndDriftFlaggedCount;
  final double overallScore;
  final List<String> problemTags;

  const ScoreSummary({
    required this.noteCount,
    required this.missedCount,
    required this.centsGreen,
    required this.centsYellow,
    required this.centsRed,
    required this.timingFlaggedCount,
    required this.stabilityFlaggedCount,
    required this.phraseEndDriftFlaggedCount,
    required this.overallScore,
    required this.problemTags,
  });

  factory ScoreSummary.fromJson(Map<String, dynamic> json) => ScoreSummary(
        noteCount: json['note_count'] as int,
        missedCount: json['missed_count'] as int,
        centsGreen: json['cents_green'] as int,
        centsYellow: json['cents_yellow'] as int,
        centsRed: json['cents_red'] as int,
        timingFlaggedCount: json['timing_flagged_count'] as int,
        stabilityFlaggedCount: json['stability_flagged_count'] as int,
        phraseEndDriftFlaggedCount: json['phrase_end_drift_flagged_count'] as int,
        overallScore: (json['overall_score'] as num).toDouble(),
        problemTags: (json['problem_tags'] as List).cast<String>(),
      );
}

class ScoreResult {
  final List<ScoreNote> notes;
  final ScoreSummary summary;

  const ScoreResult({required this.notes, required this.summary});

  factory ScoreResult.fromJson(Map<String, dynamic> json) => ScoreResult(
        notes: (json['notes'] as List)
            .cast<Map<String, dynamic>>()
            .map(ScoreNote.fromJson)
            .toList(),
        summary: ScoreSummary.fromJson(json['summary'] as Map<String, dynamic>),
      );
}
```

- [ ] **Step 4: `mobile/lib/api/api_client.dart` — `postJson` ergänzen**

Füge nach der bestehenden `postMultipart`-Methode (`mobile/lib/api/api_client.dart:59-84`), vor der abschließenden `}` der Klasse, hinzu:

```dart

  Future<Map<String, dynamic>> postJson(String path, Map<String, dynamic> body) async {
    final response = await _http.post(
      _uri(path),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    return _decode(response);
  }
```

(`jsonEncode` ist bereits über `import 'dart:convert';` am Dateianfang verfügbar, kein neuer Import nötig.)

- [ ] **Step 5: `mobile/lib/api/score_api.dart` anlegen**

```dart
import '../models/score_result.dart';
import '../models/sung_point.dart';
import 'api_client.dart';

/// Ruft POST /api/score auf (backend/api/routes.py::score) und liefert das
/// geparste Bewertungsergebnis. Nimmt die Zielkurve als bereits serialisiertes
/// JSON entgegen (nicht als TargetPoint-Liste), da der Aufrufer je nach Modus
/// entweder TargetPoint- oder SungPoint-Objekte serialisiert (siehe SessionState.score()).
class ScoreApi {
  final ApiClient _client;

  ScoreApi(this._client);

  Future<ScoreResult> score(
    List<Map<String, dynamic>> targetCurveJson,
    List<SungPoint> alignedSungCurve,
  ) async {
    final json = await _client.postJson('/api/score', {
      'target_curve': targetCurveJson,
      'sung_curve': alignedSungCurve.map((p) => p.toJson()).toList(),
    });
    return ScoreResult.fromJson(json['score'] as Map<String, dynamic>);
  }
}
```

- [ ] **Step 6: Statische Analyse laufen lassen**

Run: `cd mobile && flutter analyze`
Expected: keine neuen Fehler/Warnungen zu den fünf geänderten/neuen Dateien.

- [ ] **Step 7: Commit**

```bash
git add mobile/lib/models/target_point.dart mobile/lib/models/sung_point.dart mobile/lib/models/score_result.dart mobile/lib/api/api_client.dart mobile/lib/api/score_api.dart
git commit -m "feat: add ScoreApi and toJson() serialization to mobile API layer"
```

---

### Task 9: `SessionState` — automatische Bewertung nach dem Alignment

**Files:**
- Modify: `mobile/lib/state/session_state.dart`
- Modify: `mobile/test/session_state_test.dart`

**Interfaces:**
- Consumes: `ScoreApi.score` (Task 8).
- Produces: `SessionState.scoreResult` (`ScoreResult?`), `SessionState.scoreStatus`/`scoreMessage`, `SessionState.score()` (`Future<void>`, wird intern von `align()` aufgerufen).

- [ ] **Step 1: `_FakeApiClient` in `mobile/test/session_state_test.dart` erweitern + neue Tests schreiben**

Ersetze den Import-Block (`mobile/test/session_state_test.dart:1-10`) durch:

```dart
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:singing_feedback_mobile/api/api_client.dart';
import 'package:singing_feedback_mobile/api/audio_api.dart';
import 'package:singing_feedback_mobile/api/midi_api.dart';
import 'package:singing_feedback_mobile/api/score_api.dart';
import 'package:singing_feedback_mobile/api/sync_api.dart';
import 'package:singing_feedback_mobile/models/target_point.dart';
import 'package:singing_feedback_mobile/state/session_state.dart';
```

Ersetze `_FakeApiClient` (`mobile/test/session_state_test.dart:12-45`) durch:

```dart
class _FakeApiClient extends ApiClient {
  _FakeApiClient() : super(baseUrl: 'http://fake.local');

  @override
  Future<Map<String, dynamic>> postMultipart(
    String path, {
    required String fieldName,
    required Uint8List bytes,
    required String filename,
    Map<String, String>? fields,
    String? secondFieldName,
    Uint8List? secondBytes,
    String? secondFilename,
  }) async {
    if (path == '/api/sync/align') {
      return {
        'target_curve': [
          {'t': 0.0, 'hz': 440.0, 'midi_note': 69},
        ],
        'sung_curve': [
          {'t': 0.0, 'hz': 440.0, 'voiced': true, 'confidence': 0.9, 'aligned_t': 0.05},
          {'t': 0.01, 'hz': null, 'voiced': false, 'confidence': 0.0, 'aligned_t': null},
        ],
        'target_duration': 1.0,
      };
    }
    return {
      'curve': [
        {'t': 0.0, 'hz': 440.0, 'voiced': true, 'confidence': 0.9},
        {'t': 0.01, 'hz': null, 'voiced': false, 'confidence': 0.0},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> postJson(String path, Map<String, dynamic> body) async {
    return {
      'score': {
        'notes': [
          {
            'index': 0, 'start_t': 0.0, 'end_t': 1.0,
            'target_hz': 440.0, 'target_midi_note': 69,
            'missed': false, 'coverage_fraction': 1.0,
            'cents_deviation': {'value': 1.2, 'classification': 'green'},
            'timing': {'deviation_ms': 4.0, 'classification': 'on_time'},
            'held': true,
            'stability': {'applicable': true, 'mad_cents': 0.8, 'flag': false},
            'phrase_end_drift': {'applicable': true, 'drift_cents': 0.3, 'flag': false, 'direction': null},
          },
        ],
        'summary': {
          'note_count': 1, 'missed_count': 0,
          'cents_green': 1, 'cents_yellow': 0, 'cents_red': 0,
          'timing_flagged_count': 0, 'stability_flagged_count': 0,
          'phrase_end_drift_flagged_count': 0,
          'overall_score': 100.0,
          'problem_tags': <String>[],
        },
      },
    };
  }
}
```

Ersetze `_buildSession()` (`mobile/test/session_state_test.dart:47-54`) durch:

```dart
SessionState _buildSession() {
  final client = _FakeApiClient();
  return SessionState(
    midiApi: MidiApi(client),
    audioApi: AudioApi(client),
    syncApi: SyncApi(client),
    scoreApi: ScoreApi(client),
  );
}
```

Füge am Ende von `main()` (nach dem letzten bestehenden Test, `mobile/test/session_state_test.dart:249-265`), vor der abschließenden `}`, hinzu:

```dart

  test('align() loest automatisch score() aus und befuellt scoreResult (MIDI-Modus)',
      () async {
    final session = _buildSession();
    session.midiSessionId = 'sess-1';
    session.selectedTrackIndex = 0;
    session.targetCurve = const [TargetPoint(t: 0.0, hz: 440.0, midiNote: 69)];

    await session.analyzeAudio(Uint8List.fromList([1, 2, 3]), 'gesang.wav');

    expect(session.scoreStatus, LoadStatus.ok);
    expect(session.scoreResult, isNotNull);
    expect(session.scoreResult!.notes.length, 1);
    expect(session.scoreResult!.summary.overallScore, closeTo(100.0, 0.001));
  });

  test('align() loest score() im Referenz-Modus mit referenceRawCurve aus', () async {
    final session = _buildSession();
    session.setReferenceSource(ReferenceSource.recording);
    await session.analyzeReference(Uint8List.fromList([9, 9, 9]), 'referenz.wav');

    await session.analyzeAudio(Uint8List.fromList([1, 2, 3]), 'gesang.wav');

    expect(session.scoreStatus, LoadStatus.ok);
    expect(session.scoreResult, isNotNull);
  });

  test('setReferenceSource setzt scoreResult/scoreStatus zurueck', () async {
    final session = _buildSession();
    session.midiSessionId = 'sess-1';
    session.selectedTrackIndex = 0;
    session.targetCurve = const [TargetPoint(t: 0.0, hz: 440.0, midiNote: 69)];
    await session.analyzeAudio(Uint8List.fromList([1, 2, 3]), 'gesang.wav');
    expect(session.scoreResult, isNotNull);

    session.setReferenceSource(ReferenceSource.recording);

    expect(session.scoreResult, isNull);
    expect(session.scoreStatus, LoadStatus.idle);
  });

  test('selectTrack setzt scoreResult/scoreStatus zurueck (neue Zielmelodie)', () async {
    final session = _buildSession();
    session.midiSessionId = 'sess-1';
    session.selectedTrackIndex = 0;
    session.targetCurve = const [TargetPoint(t: 0.0, hz: 440.0, midiNote: 69)];
    await session.analyzeAudio(Uint8List.fromList([1, 2, 3]), 'gesang.wav');
    expect(session.scoreResult, isNotNull);

    await session.selectTrack(1);

    expect(session.scoreResult, isNull);
    expect(session.scoreStatus, LoadStatus.idle);
  });
```

- [ ] **Step 2: Tests laufen lassen, FAIL erwarten**

Run: `cd mobile && flutter test test/session_state_test.dart`
Expected: FAIL — `SessionState` kennt weder den `scoreApi`-Konstruktorparameter noch `scoreResult`/`scoreStatus`/`score()` (Compile-Fehler), und `_FakeApiClient.postJson` ist ein `@override` einer noch nicht existierenden Basis-Methode (löst sich in Task 8 schon auf, falls Task 8 vor diesem Task läuft — hier nur zur Kontrolle nochmal ausführen).

- [ ] **Step 3: `mobile/lib/state/session_state.dart` erweitern**

Imports ergänzen (nach `import '../api/sync_api.dart';`, `mobile/lib/state/session_state.dart:8`):

```dart
import '../api/score_api.dart';
import '../models/score_result.dart';
```

Konstruktor (`mobile/lib/state/session_state.dart:19-24`) ersetzen durch:

```dart
class SessionState extends ChangeNotifier {
  final MidiApi midiApi;
  final AudioApi audioApi;
  final SyncApi syncApi;
  final ScoreApi scoreApi;

  SessionState({
    required this.midiApi,
    required this.audioApi,
    required this.syncApi,
    required this.scoreApi,
  });
```

Nach den `alignedSungCurve`/`alignStatus`/`alignMessage`-Feldern (`mobile/lib/state/session_state.dart:46-48`) ergänzen:

```dart

  ScoreResult? scoreResult;
  LoadStatus scoreStatus = LoadStatus.idle;
  String scoreMessage = '';
```

`align()`'s Erfolgspfad (`mobile/lib/state/session_state.dart:200-202`) — ersetze

```dart
      alignStatus = LoadStatus.ok;
      alignMessage = 'Ausrichtung fertig.';
    } catch (e) {
```

durch

```dart
      alignStatus = LoadStatus.ok;
      alignMessage = 'Ausrichtung fertig.';
      notifyListeners();
      await score();
      return;
    } catch (e) {
```

(Direkt danach folgt im bestehenden Code bereits `alignStatus = LoadStatus.error; ...` im `catch`-Block und ein abschließendes `notifyListeners();` — die bestehende Struktur bleibt sonst unverändert, nur der `try`-Block bekommt vor seinem Ende ein `notifyListeners(); await score(); return;` eingefügt, exakt wie `analyzeAudio()` das bereits für `align()` selbst macht.)

Nach der `align()`-Methode (`mobile/lib/state/session_state.dart:173-210`, vor `analyzeReference`) die neue Methode einfügen:

```dart

  /// Bewertet die ausgerichtete Gesangskurve gegen die Zielmelodie (POST /api/score).
  /// Wird automatisch am Ende eines erfolgreichen align() angestossen - kein
  /// manueller Button, gleiches Prinzip wie align() nach analyzeAudio(). Nutzt
  /// bewusst NICHT displayedTargetCurve (im Referenz-Modus clientseitig transponiert
  /// fuer die Chart-Anzeige) - das Backend hat beim Alignment die UNTRANSPONIERTE
  /// referenceRawCurve gesehen, score() muss also dieselbe Kurve verwenden.
  Future<void> score() async {
    if (alignedSungCurve.isEmpty) return;
    scoreStatus = LoadStatus.loading;
    scoreMessage = 'Werte Aufnahme aus…';
    notifyListeners();
    try {
      final targetCurveJson = referenceSource == ReferenceSource.midi
          ? targetCurve.map((p) => p.toJson()).toList()
          : referenceRawCurve.map((p) => p.toJson()).toList();
      scoreResult = await scoreApi.score(targetCurveJson, alignedSungCurve);
      scoreStatus = LoadStatus.ok;
      scoreMessage = 'Bewertung fertig.';
    } catch (e) {
      scoreStatus = LoadStatus.error;
      scoreMessage = 'Bewertung fehlgeschlagen: ${_messageOf(e)}';
    }
    notifyListeners();
  }
```

`_resetAlignment()` (`mobile/lib/state/session_state.dart:257-261`) ersetzen durch:

```dart
  void _resetAlignment() {
    alignedSungCurve = [];
    alignStatus = LoadStatus.idle;
    alignMessage = '';
    scoreResult = null;
    scoreStatus = LoadStatus.idle;
    scoreMessage = '';
  }
```

- [ ] **Step 4: Tests laufen lassen**

Run: `cd mobile && flutter test test/session_state_test.dart`
Expected: alle Tests (bestehende + 4 neue) PASS.

- [ ] **Step 5: Vollen Mobile-Testlauf zur Regressionsprüfung**

Run: `cd mobile && flutter test`
Expected: alle Tests PASS außer ggf. `widget_test.dart` (falls Task 10 noch nicht gelaufen ist, kompiliert `main.dart` ohne `scoreApi`-Argument nicht — analog zu Phase 3s Task 7/8-Übergang; das ist erwartet und wird in Task 10 behoben).

- [ ] **Step 6: Commit**

```bash
git add mobile/lib/state/session_state.dart mobile/test/session_state_test.dart
git commit -m "feat: auto-trigger scoring after DTW alignment"
```

---

### Task 10: Bewertungs-Anzeige (`ScoreSummaryView`, `HomeScreen`, `main.dart`)

**Files:**
- Create: `mobile/lib/widgets/score_summary_view.dart`
- Modify: `mobile/lib/screens/home_screen.dart`
- Modify: `mobile/lib/main.dart`

**Interfaces:**
- Consumes: `SessionState.scoreResult`/`scoreStatus`/`scoreMessage` (Task 9), `ScoreResult`/`ScoreNote`/`ScoreSummary` (Task 8).
- Produces: nichts Neues nach außen — reines Anzeige-Widget + Verdrahtung.

Kein neuer automatisierter Test (Projektkonvention: keine Pixel-/Golden-Tests für Widgets in diesem Repo). Verifikation über `flutter analyze` + manuellen App-Lauf.

- [ ] **Step 1: `mobile/lib/widgets/score_summary_view.dart` anlegen**

```dart
import 'package:flutter/material.dart';

import '../models/score_result.dart';

/// Einfache Text-/Zahlen-Zusammenfassung der Bewertungs-Engine (Phase 4,
/// Kernpaket) - bewusst OHNE Kurvenfaerbung im Chart (das ist die spaetere,
/// separate Phase 5). Eine Zeile pro Note plus eine Zusammenfassungszeile.
class ScoreSummaryView extends StatelessWidget {
  final ScoreResult result;

  const ScoreSummaryView({super.key, required this.result});

  Color _classificationColor(String classification) => switch (classification) {
        'green' => Colors.green.shade300,
        'yellow' => Colors.amber.shade300,
        _ => Colors.red.shade300,
      };

  String _noteLabel(ScoreNote note) {
    final parts = <String>[
      note.centsValue == null ? '–¢' : '${note.centsValue!.toStringAsFixed(0)}¢',
    ];
    if (note.timingClassification != 'on_time') {
      parts.add(note.timingClassification == 'too_early' ? 'zu früh' : 'zu spät');
    }
    if (note.phraseEndDriftFlag) parts.add('Phrasenende driftet');
    if (note.stabilityFlag) parts.add('instabil');
    if (note.missed) parts.add('verfehlt');
    return 'Note ${note.index + 1}: ${parts.join(' · ')}';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final note in result.notes)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(
              _noteLabel(note),
              style: TextStyle(color: _classificationColor(note.centsClassification)),
            ),
          ),
        const SizedBox(height: 8),
        Text(
          '${result.summary.missedCount} verfehlt · ${result.summary.centsYellow} gelb · '
          '${result.summary.centsRed} rot · Gesamt: ${result.summary.overallScore.toStringAsFixed(0)}',
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}
```

- [ ] **Step 2: `mobile/lib/screens/home_screen.dart` — Abschnitt "4. Bewertung" ergänzen**

Import ergänzen (nach `import '../widgets/recording_control.dart';`, `mobile/lib/screens/home_screen.dart:8`):

```dart
import '../widgets/score_summary_view.dart';
```

Nach dem bestehenden `PitchChart`-Block (`mobile/lib/screens/home_screen.dart:121-128`), vor den abschließenden `],`/`),`/`),`/`);` der `ListView`, ergänzen:

```dart
            const Divider(height: 32),
            Text('4. Bewertung', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            StatusBanner(status: session.scoreStatus, message: session.scoreMessage),
            if (session.scoreResult != null) ScoreSummaryView(result: session.scoreResult!),
```

- [ ] **Step 3: `mobile/lib/main.dart` — `ScoreApi` verdrahten**

Import ergänzen (nach `import 'api/sync_api.dart';`, `mobile/lib/main.dart:8`):

```dart
import 'api/score_api.dart';
```

`SessionState`-Konstruktion (`mobile/lib/main.dart:23-27`) erweitern:

```dart
      create: (_) => SessionState(
        midiApi: MidiApi(apiClient),
        audioApi: AudioApi(apiClient),
        syncApi: SyncApi(apiClient),
        scoreApi: ScoreApi(apiClient),
      ),
```

- [ ] **Step 4: Statische Analyse + vollständiger Testlauf**

Run: `cd mobile && flutter analyze && flutter test`
Expected: keine neuen Analyzer-Fehler, alle Tests PASS (inkl. `widget_test.dart`, das jetzt wieder kompiliert).

- [ ] **Step 5: Manuelle Verifikation im Emulator/Gerät**

Backend starten (`.venv/bin/python run.py`), App starten (`cd mobile && flutter run`), MIDI hochladen, Spur wählen, `tests/fixtures/test_vocal.wav` als Aufnahme hochladen, beobachten, dass nach "Richte Aufnahme zeitlich aus…" ein "Werte Aufnahme aus…" folgt und darunter der neue Abschnitt "4. Bewertung" mit 5 Notenzeilen und einer Zusammenfassungszeile erscheint (Note 2 mit "zu früh", Note 3 mit "Phrasenende driftet", entsprechend eingefärbt).

- [ ] **Step 6: Commit**

```bash
git add mobile/lib/widgets/score_summary_view.dart mobile/lib/screens/home_screen.dart mobile/lib/main.dart
git commit -m "feat: display scoring results in a new Bewertung section"
```

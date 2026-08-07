# Bessere Spurerkennung & Hörprobe (Phase 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Phase-1 tuple-based track-candidate sort with a real weighted heuristic score (0–100), surface it in the mobile UI, and add a Sinus-synth audio preview per MIDI track candidate so users can listen before selecting.

**Architecture:** Backend gains a pure scoring function inside `backend/midi_analysis/parser.py` (5 weighted sub-scores summed to 0–100) and a new `backend/midi_analysis/preview.py` module that additively synthesizes a capped WAV preview per track, exposed via a new `GET /api/midi/{session_id}/track-preview` endpoint (same session-reuse pattern as the existing `track-curve` endpoint). Mobile gains a `score` field on `TrackCandidate`, a color-coded badge on `TrackCandidateCard`, and a `TrackPreviewButton` that lazily fetches preview bytes into a `SessionState`-owned cache and plays them through the already-centralized `SessionState` audio player (no new `AudioPlayer` instance).

**Tech Stack:** Python/FastAPI/pretty_midi/soundfile/numpy (backend), Flutter/Dart/provider/audioplayers (mobile), pytest, flutter_test.

## Global Constraints

- No new external dependencies — only `numpy`, `pretty_midi`, `soundfile` (all already project dependencies) on the backend, and existing `http`/`audioplayers`/`provider` packages on mobile.
- No Soundfont/FluidSynth — preview audio is additive sine + overtones only (matches `PLAN.md`'s existing "Getroffene Annahmen").
- Backend numeric tuning constants live in `backend/config.py`, following the existing convention (see `CENTS_GREEN_THRESHOLD` etc.).
- Mobile playback must go through the existing centralized `SessionState` player (`SessionState.play`/`pause`/`isPlayingAudio`) — never construct a new `AudioPlayer` in a widget (see `docs/superpowers/specs/2026-08-06-feedback-jump-to-audio-design.md` for why).
- Reuse the exact existing color values for score tiers: `Colors.green.shade300` / `Colors.amber.shade300` / `Colors.red.shade300` (matches `PitchChart`/`ScoreSummaryView`).

---

### Task 1: Backend — gewichteter Track-Score

**Files:**
- Modify: `backend/config.py`
- Modify: `backend/midi_analysis/parser.py`
- Test: `tests/test_midi_analysis.py`

**Interfaces:**
- Consumes: nothing new.
- Produces: `TrackCandidate.score: float` (dataclass field, 0–100). `TrackCandidate.to_dict()` includes `"score": round(float(self.score), 1)`. `list_track_candidates()` sorts candidates by `score` descending.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_midi_analysis.py`:

```python
def test_score_rewards_name_hint_match():
    import pretty_midi

    pm = pretty_midi.PrettyMIDI()
    for name in ("Vocal", "Synth"):
        inst = pretty_midi.Instrument(program=0, name=name)
        for i in range(8):
            inst.notes.append(pretty_midi.Note(velocity=90, pitch=60, start=i * 0.5, end=i * 0.5 + 0.4))
        pm.instruments.append(inst)

    candidates = list_track_candidates(pm)
    by_name = {c.name: c for c in candidates}
    assert by_name["Vocal"].score - by_name["Synth"].score == 20.0


def test_score_rewards_monophonic_over_polyphonic():
    import pretty_midi

    pm = pretty_midi.PrettyMIDI()
    mono = pretty_midi.Instrument(program=0, name="Mono")
    for i in range(8):
        mono.notes.append(pretty_midi.Note(velocity=90, pitch=60, start=i * 0.5, end=i * 0.5 + 0.4))
    pm.instruments.append(mono)

    poly = pretty_midi.Instrument(program=0, name="Poly")
    for i in range(8):
        for pitch in (60, 64, 67):
            poly.notes.append(pretty_midi.Note(velocity=90, pitch=pitch, start=i * 0.5, end=i * 0.5 + 0.4))
    pm.instruments.append(poly)

    candidates = list_track_candidates(pm)
    by_name = {c.name: c for c in candidates}
    assert by_name["Mono"].score > by_name["Poly"].score


def test_score_is_zero_for_drum_tracks():
    import pretty_midi

    pm = pretty_midi.PrettyMIDI()
    drum = pretty_midi.Instrument(program=0, is_drum=True, name="Drums")
    for i in range(4):
        drum.notes.append(pretty_midi.Note(velocity=90, pitch=36, start=i * 0.2, end=i * 0.2 + 0.1))
    pm.instruments.append(drum)

    candidates = list_track_candidates(pm)
    assert candidates[0].score == 0.0


def test_score_rewards_pitch_within_vocal_window():
    import pretty_midi

    pm = pretty_midi.PrettyMIDI()
    in_range = pretty_midi.Instrument(program=0, name="InRange")
    for i in range(8):
        in_range.notes.append(pretty_midi.Note(velocity=90, pitch=60, start=i * 0.5, end=i * 0.5 + 0.4))
    pm.instruments.append(in_range)

    out_of_range = pretty_midi.Instrument(program=0, name="OutOfRange")
    for i in range(8):
        out_of_range.notes.append(pretty_midi.Note(velocity=90, pitch=100, start=i * 0.5, end=i * 0.5 + 0.4))
    pm.instruments.append(out_of_range)

    candidates = list_track_candidates(pm)
    by_name = {c.name: c for c in candidates}
    assert by_name["InRange"].score > by_name["OutOfRange"].score


def test_score_rewards_duration_closer_to_longest_track():
    import pretty_midi

    pm = pretty_midi.PrettyMIDI()
    long_track = pretty_midi.Instrument(program=0, name="Long")
    for i in range(20):
        long_track.notes.append(pretty_midi.Note(velocity=90, pitch=60, start=i * 0.5, end=i * 0.5 + 0.4))
    pm.instruments.append(long_track)  # ~9.9s Dauer

    short_track = pretty_midi.Instrument(program=0, name="Short")
    for i in range(4):
        short_track.notes.append(pretty_midi.Note(velocity=90, pitch=60, start=i * 0.5, end=i * 0.5 + 0.4))
    pm.instruments.append(short_track)  # ~1.9s Dauer, deutlich unter 30% von 9.9s

    candidates = list_track_candidates(pm)
    by_name = {c.name: c for c in candidates}
    assert by_name["Long"].score > by_name["Short"].score


def test_score_penalizes_very_high_note_density():
    import pretty_midi

    pm = pretty_midi.PrettyMIDI()
    normal = pretty_midi.Instrument(program=0, name="Normal")
    for i in range(8):
        normal.notes.append(pretty_midi.Note(velocity=90, pitch=60, start=i * 0.5, end=i * 0.5 + 0.4))
    pm.instruments.append(normal)  # ~2 Noten/Sek, im Zielfenster

    dense = pretty_midi.Instrument(program=0, name="Dense")
    for i in range(80):
        dense.notes.append(pretty_midi.Note(velocity=90, pitch=60, start=i * 0.05, end=i * 0.05 + 0.04))
    pm.instruments.append(dense)  # ~20 Noten/Sek, deutlich ueber dem Zielfenster

    candidates = list_track_candidates(pm)
    by_name = {c.name: c for c in candidates}
    assert by_name["Normal"].score > by_name["Dense"].score
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m pytest tests/test_midi_analysis.py -v`
Expected: the 6 new tests FAIL with `AttributeError: 'TrackCandidate' object has no attribute 'score'`.

- [ ] **Step 3: Add scoring constants to config.py**

Append to `backend/config.py`:

```python
# Spurerkennung (Phase 2): Gewichteter Score je Kandidat (0-100), ersetzt die reine
# Tuple-Sortierung aus Phase 1. Siehe
# docs/superpowers/specs/2026-08-07-track-scoring-and-preview-design.md.
TRACK_SCORE_VOCAL_RANGE_MIDI_MIN = 43  # ~G2, grosszuegige untere Grenze
TRACK_SCORE_VOCAL_RANGE_MIDI_MAX = 84  # ~C6, grosszuegige obere Grenze
TRACK_SCORE_DENSITY_MIN_NOTES_PER_SEC = 0.5
TRACK_SCORE_DENSITY_MAX_NOTES_PER_SEC = 4.0
TRACK_SCORE_DURATION_RATIO_FULL_SCORE = 0.3  # ab 30% der laengsten Spur volle Punktzahl
```

- [ ] **Step 4: Implement the scoring function in parser.py**

In `backend/midi_analysis/parser.py`, add the import and helper functions, add the `score` field to `TrackCandidate`, update `to_dict()`, and update `list_track_candidates()`:

```python
# Import to add near the top, after `import pretty_midi`:
from backend.config import (
    TRACK_SCORE_DENSITY_MAX_NOTES_PER_SEC,
    TRACK_SCORE_DENSITY_MIN_NOTES_PER_SEC,
    TRACK_SCORE_DURATION_RATIO_FULL_SCORE,
    TRACK_SCORE_VOCAL_RANGE_MIDI_MAX,
    TRACK_SCORE_VOCAL_RANGE_MIDI_MIN,
)

_SCORE_WEIGHT = 20.0
```

Add `score: float = 0.0` as a new field on the `TrackCandidate` dataclass (after `plausible`, before `warnings`), and add `"score": round(float(self.score), 1),` to `to_dict()` (after the `"plausible"` entry).

Add these module-level helper functions above `list_track_candidates`:

```python
def _pitch_range_fraction(pitch_min: int, pitch_max: int) -> float:
    """Anteil von [pitch_min, pitch_max], der innerhalb des grosszuegigen
    Gesangsfensters liegt (1.0 = komplett drin, 0.0 = komplett draussen)."""
    lo = max(pitch_min, TRACK_SCORE_VOCAL_RANGE_MIDI_MIN)
    hi = min(pitch_max, TRACK_SCORE_VOCAL_RANGE_MIDI_MAX)
    overlap = max(0, hi - lo + 1)
    span = pitch_max - pitch_min + 1
    return overlap / span


def _note_density_fraction(note_count: int, duration_seconds: float) -> float:
    """Volle Punktzahl im plausiblen Notendichte-Fenster, linearer Abfall auf 0
    ausserhalb in beide Richtungen."""
    if duration_seconds <= 0:
        return 0.0
    density = note_count / duration_seconds
    if density < TRACK_SCORE_DENSITY_MIN_NOTES_PER_SEC:
        return max(0.0, density / TRACK_SCORE_DENSITY_MIN_NOTES_PER_SEC)
    if density <= TRACK_SCORE_DENSITY_MAX_NOTES_PER_SEC:
        return 1.0
    falloff_range = TRACK_SCORE_DENSITY_MAX_NOTES_PER_SEC
    return max(0.0, 1.0 - (density - TRACK_SCORE_DENSITY_MAX_NOTES_PER_SEC) / falloff_range)


def _duration_ratio_fraction(duration_seconds: float, longest_duration_seconds: float) -> float:
    """Volle Punktzahl ab TRACK_SCORE_DURATION_RATIO_FULL_SCORE Anteil an der
    laengsten Spur der Datei (Proxy fuer die Songlaenge)."""
    if longest_duration_seconds <= 0:
        return 0.0
    ratio = duration_seconds / longest_duration_seconds
    return min(1.0, ratio / TRACK_SCORE_DURATION_RATIO_FULL_SCORE)


def _compute_score(
    *,
    is_drum: bool,
    note_count: int,
    pitch_min: int | None,
    pitch_max: int | None,
    duration_seconds: float,
    monophonic: bool,
    name_hint_match: bool,
    longest_duration_seconds: float,
) -> float:
    if is_drum or note_count == 0 or pitch_min is None or pitch_max is None:
        return 0.0
    score = 0.0
    score += _SCORE_WEIGHT if name_hint_match else 0.0
    score += _SCORE_WEIGHT if monophonic else 0.0
    score += _SCORE_WEIGHT * _pitch_range_fraction(pitch_min, pitch_max)
    score += _SCORE_WEIGHT * _note_density_fraction(note_count, duration_seconds)
    score += _SCORE_WEIGHT * _duration_ratio_fraction(duration_seconds, longest_duration_seconds)
    return score
```

Then update `list_track_candidates()`: after the existing `for idx, inst in enumerate(...)` loop finishes building `candidates` (right before the current `candidates.sort(...)` line), insert a second pass that computes `longest_duration_seconds` and assigns `.score` to every candidate, and replace the sort key:

```python
    longest_duration_seconds = max((c.duration_seconds for c in candidates), default=0.0)
    for c in candidates:
        c.score = _compute_score(
            is_drum=c.is_drum,
            note_count=c.note_count,
            pitch_min=c.pitch_min,
            pitch_max=c.pitch_max,
            duration_seconds=c.duration_seconds,
            monophonic=c.monophonic,
            name_hint_match=c.name_hint_match,
            longest_duration_seconds=longest_duration_seconds,
        )

    # Score fasst Namenstreffer/Monophonie/Stimmumfang/Notendichte/Dauer-Plausibilitaet
    # zusammen, damit die wahrscheinlichste Gesangsspur oben steht (der Nutzer waehlt
    # trotzdem selbst).
    candidates.sort(key=lambda c: -c.score)
```

Remove the old `candidates.sort(key=lambda c: (not c.name_hint_match, not c.plausible, not c.monophonic, -c.note_count))` line and its preceding comment — replaced by the block above.

- [ ] **Step 5: Run tests to verify they pass**

Run: `python -m pytest tests/test_midi_analysis.py -v`
Expected: all tests PASS, including the 6 new ones and the pre-existing `test_vocal_track_is_detected_first_and_plausible` / `test_drum_and_polyphonic_tracks_are_marked_implausible`.

- [ ] **Step 6: Run the full backend test suite for regressions**

Run: `python -m pytest tests/ -v`
Expected: all tests PASS (in particular `tests/test_e2e_phase1.py`, which calls `list_track_candidates` but doesn't assert on ordering/score, should be unaffected).

- [ ] **Step 7: Commit**

```bash
git add backend/config.py backend/midi_analysis/parser.py tests/test_midi_analysis.py
git commit -m "feat: replace tuple sort with a weighted 0-100 track candidate score"
```

---

### Task 2: Backend — Sinus-Synth-Hörprobe + Endpoint

**Files:**
- Create: `backend/midi_analysis/preview.py`
- Modify: `backend/midi_analysis/__init__.py`
- Modify: `backend/config.py`
- Modify: `backend/api/routes.py`
- Test: Create `tests/test_midi_preview.py`

**Interfaces:**
- Consumes: nothing new (independent of Task 1).
- Produces: `synthesize_track_preview(pm, track_index, transpose_semitones=0, max_seconds=TRACK_PREVIEW_MAX_SECONDS, sample_rate=TRACK_PREVIEW_SAMPLE_RATE) -> bytes` exported from `backend.midi_analysis`. New endpoint `GET /api/midi/{session_id}/track-preview?track_index=N&transpose=0` returning `audio/wav` bytes.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_midi_preview.py`:

```python
import io
from pathlib import Path

import numpy as np
import pretty_midi
import pytest
import soundfile as sf

from backend.config import TRACK_PREVIEW_SAMPLE_RATE
from backend.midi_analysis import load_midi, synthesize_track_preview

from .fixtures.generate_fixtures import generate

FIXTURES_DIR = Path(__file__).resolve().parent / "fixtures"


def _load_reference():
    midi_path, _ = generate(FIXTURES_DIR)
    return load_midi(midi_path.read_bytes())


def test_preview_is_valid_decodable_wav():
    pm = _load_reference()
    wav_bytes = synthesize_track_preview(pm, track_index=0)
    audio, sr = sf.read(io.BytesIO(wav_bytes))
    assert sr == TRACK_PREVIEW_SAMPLE_RATE
    assert len(audio) > 0


def test_preview_duration_is_capped_at_max_seconds():
    pm = _load_reference()  # test_reference.mid Melodie ist 5.0s lang (siehe MELODY)
    wav_bytes = synthesize_track_preview(pm, track_index=0, max_seconds=2.0)
    audio, sr = sf.read(io.BytesIO(wav_bytes))
    duration = len(audio) / sr
    assert duration <= 2.01  # kleine Toleranz fuer Rundung auf ganze Samples


def test_preview_of_empty_track_is_silence_not_error():
    pm = pretty_midi.PrettyMIDI()
    inst = pretty_midi.Instrument(program=0, name="Empty")
    pm.instruments.append(inst)

    wav_bytes = synthesize_track_preview(pm, track_index=0, max_seconds=1.0)
    audio, sr = sf.read(io.BytesIO(wav_bytes))
    assert np.allclose(audio, 0.0)


def test_preview_applies_transposition():
    pm = _load_reference()
    wav_low = synthesize_track_preview(pm, track_index=0, max_seconds=1.0)
    wav_high = synthesize_track_preview(pm, track_index=0, transpose_semitones=12, max_seconds=1.0)
    assert wav_low != wav_high


def test_preview_invalid_track_index_raises_value_error():
    pm = _load_reference()
    with pytest.raises(ValueError):
        synthesize_track_preview(pm, track_index=99)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m pytest tests/test_midi_preview.py -v`
Expected: FAIL with `ImportError: cannot import name 'synthesize_track_preview'`.

- [ ] **Step 3: Add preview constants to config.py**

Append to `backend/config.py`:

```python
# Spurerkennung: Hoerprobe (Sinus-/Obertonsynthesizer, kein Soundfont - siehe PLAN.md).
TRACK_PREVIEW_MAX_SECONDS = 15.0
TRACK_PREVIEW_SAMPLE_RATE = 22050
```

- [ ] **Step 4: Implement the synthesizer**

Create `backend/midi_analysis/preview.py`:

```python
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
```

Update `backend/midi_analysis/__init__.py`:

```python
from .parser import TrackCandidate, load_midi, list_track_candidates, track_pitch_curve
from .preview import synthesize_track_preview

__all__ = [
    "TrackCandidate",
    "load_midi",
    "list_track_candidates",
    "track_pitch_curve",
    "synthesize_track_preview",
]
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `python -m pytest tests/test_midi_preview.py -v`
Expected: all 5 tests PASS.

- [ ] **Step 6: Wire the endpoint**

In `backend/api/routes.py`:

Change the fastapi import line to include `Response`:

```python
from fastapi import APIRouter, Depends, File, Form, HTTPException, Request, Response, UploadFile
```

Change the midi_analysis import to also bring in `synthesize_track_preview`:

```python
from backend.midi_analysis import list_track_candidates, load_midi, synthesize_track_preview, track_pitch_curve
```

Add a new endpoint directly below the existing `get_track_curve` endpoint (after its closing `return {"curve": curve}` line, before `@router.delete("/midi/{session_id}")`):

```python
@router.get("/midi/{session_id}/track-preview")
async def get_track_preview(session_id: str, track_index: int, transpose: int = 0) -> Response:
    pm = MIDI_SESSIONS.get(session_id)
    if pm is None:
        raise HTTPException(
            status_code=404,
            detail="MIDI-Session nicht gefunden oder abgelaufen - bitte Datei erneut hochladen.",
        )
    try:
        wav_bytes = synthesize_track_preview(pm, track_index, transpose_semitones=transpose)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    return Response(content=wav_bytes, media_type="audio/wav")
```

No rate limit dependency here — same reasoning as the existing `track-curve` endpoint: the work is bounded by `TRACK_PREVIEW_MAX_SECONDS` and requires an existing session (already rate-limited at `/api/midi/upload`).

- [ ] **Step 7: Run the full backend test suite for regressions**

Run: `python -m pytest tests/ -v`
Expected: all tests PASS.

- [ ] **Step 8: Commit**

```bash
git add backend/midi_analysis/preview.py backend/midi_analysis/__init__.py backend/config.py backend/api/routes.py tests/test_midi_preview.py
git commit -m "feat: add Sinus-synth track preview and GET /api/midi/{id}/track-preview endpoint"
```

---

### Task 3: Mobile — TrackCandidate.score-Feld + Score-Badge

**Files:**
- Modify: `mobile/lib/models/track_candidate.dart`
- Modify: `mobile/lib/widgets/track_candidate_card.dart`
- Test: Create `mobile/test/track_candidate_card_test.dart`

**Interfaces:**
- Consumes: nothing runtime-coupled to Task 1 (this task supplies its own JSON fixtures in tests); relies only on the backend JSON shape `{"score": <number>, ...}` documented in the design spec.
- Produces: `TrackCandidate.score: double`. Top-level function `Color trackScoreColor(double score)` in `track_candidate_card.dart` (used directly by the test, mirrors the `colorForSungPoint` precedent in `pitch_chart.dart`).

- [ ] **Step 1: Write the failing tests**

Create `mobile/test/track_candidate_card_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:singing_feedback_mobile/models/track_candidate.dart';
import 'package:singing_feedback_mobile/widgets/track_candidate_card.dart';

TrackCandidate _candidateWithScore(double score) {
  return TrackCandidate.fromJson({
    'index': 0,
    'name': 'Vocal',
    'program': 53,
    'is_drum': false,
    'note_count': 5,
    'pitch_min': 60,
    'pitch_max': 67,
    'pitch_min_name': 'C4',
    'pitch_max_name': 'G4',
    'duration_seconds': 5.0,
    'monophonic': true,
    'name_hint_match': true,
    'plausible': true,
    'score': score,
    'warnings': <String>[],
  });
}

void main() {
  group('TrackCandidate.fromJson', () {
    test('parst das score-Feld aus der Backend-Antwort', () {
      final candidate = _candidateWithScore(78.5);
      expect(candidate.score, 78.5);
    });
  });

  group('trackScoreColor', () {
    test('Score >= 70 ist gruen', () {
      expect(trackScoreColor(70.0), Colors.green.shade300);
      expect(trackScoreColor(100.0), Colors.green.shade300);
    });

    test('Score zwischen 40 und 70 (exklusiv) ist gelb', () {
      expect(trackScoreColor(40.0), Colors.amber.shade300);
      expect(trackScoreColor(69.9), Colors.amber.shade300);
    });

    test('Score unter 40 ist rot', () {
      expect(trackScoreColor(39.9), Colors.red.shade300);
      expect(trackScoreColor(0.0), Colors.red.shade300);
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd mobile && flutter test test/track_candidate_card_test.dart`
Expected: FAIL to compile — `score` is not a parameter of `TrackCandidate.fromJson`'s expected map, and `trackScoreColor` doesn't exist.

- [ ] **Step 3: Add the score field to TrackCandidate**

In `mobile/lib/models/track_candidate.dart`, add `final double score;` to the field list (after `plausible`), add it to the constructor's required parameters, and parse it in `fromJson`:

```dart
      score: (json['score'] as num).toDouble(),
```//(insert this line in the `TrackCandidate(...)` constructor call inside `fromJson`, after `plausible: json['plausible'] as bool,`)

- [ ] **Step 4: Add trackScoreColor and the badge to TrackCandidateCard**

In `mobile/lib/widgets/track_candidate_card.dart`, add a top-level function above the `TrackCandidateCard` class:

```dart
/// Farbcodierung des 0-100 Heuristik-Scores, identisch zum bestehenden
/// Gruen/Gelb/Rot-Schema aus PitchChart/ScoreSummaryView.
Color trackScoreColor(double score) {
  if (score >= 70) return Colors.green.shade300;
  if (score >= 40) return Colors.amber.shade300;
  return Colors.red.shade300;
}
```

Then change the `build()` method's first `Text(candidate.name, ...)` line into a `Row` with a badge:

```dart
            Row(
              children: [
                Expanded(
                  child: Text(candidate.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: trackScoreColor(candidate.score).withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${candidate.score.round()}%',
                    style: TextStyle(
                      color: trackScoreColor(candidate.score),
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
```

(This replaces the existing `Text(candidate.name, style: const TextStyle(fontWeight: FontWeight.bold)),` line; everything else in `build()` stays as-is for this task.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd mobile && flutter test test/track_candidate_card_test.dart`
Expected: all 4 tests PASS.

- [ ] **Step 6: Run the full mobile test suite for regressions**

Run: `cd mobile && flutter test`
Expected: all tests PASS. (No other test constructs a `TrackCandidate` directly — confirmed by grep before writing this plan — so this is the only place the new required field matters.)

- [ ] **Step 7: Commit**

```bash
git add mobile/lib/models/track_candidate.dart mobile/lib/widgets/track_candidate_card.dart mobile/test/track_candidate_card_test.dart
git commit -m "feat: show the backend track-candidate score as a color-coded badge"
```

---

### Task 4: Mobile — Preview-Bytes-Fetching (ApiClient/MidiApi/SessionState)

**Files:**
- Modify: `mobile/lib/api/api_client.dart`
- Modify: `mobile/lib/api/midi_api.dart`
- Modify: `mobile/lib/state/session_state.dart`
- Test: Modify `mobile/test/session_state_test.dart`

**Interfaces:**
- Consumes: nothing from Tasks 1–3.
- Produces: `ApiClient.getBytes(String path, {Map<String, String>? query}) -> Future<Uint8List>`. `MidiApi.fetchTrackPreview(String sessionId, int trackIndex, {int transpose = 0}) -> Future<Uint8List>`. `SessionState.cachedPreviewBytes(int trackIndex) -> Uint8List?` and `SessionState.previewBytesForTrack(int trackIndex) -> Future<Uint8List>` (fetches on cache miss, caches, cleared on every `uploadMidi()` call).

- [ ] **Step 1: Write the failing tests**

In `mobile/test/session_state_test.dart`, add a `getBytes` override to `_FakeApiClient` (near its other overrides, after the `postJson` override):

```dart
  int getBytesCallCount = 0;

  @override
  Future<Uint8List> getBytes(String path, {Map<String, String>? query}) async {
    getBytesCallCount++;
    return Uint8List.fromList([1, 2, 3, 4]);
  }
```

Then add a new test group at the end of `main()`, before the final closing brace:

```dart
  group('SessionState Spur-Vorschau (previewBytesForTrack)', () {
    test('erster Aufruf holt Bytes ueber die API und cacht sie', () async {
      final client = _FakeApiClient();
      final session = SessionState(
        midiApi: MidiApi(client),
        audioApi: AudioApi(client),
        syncApi: SyncApi(client),
        scoreApi: ScoreApi(client),
        feedbackApi: FeedbackApi(client),
      );
      session.midiSessionId = 'session-1';

      final bytes = await session.previewBytesForTrack(0);

      expect(bytes, isNotEmpty);
      expect(client.getBytesCallCount, 1);
      expect(session.cachedPreviewBytes(0), same(bytes));
    });

    test('zweiter Aufruf fuer denselben Track nutzt den Cache statt erneut zu laden', () async {
      final client = _FakeApiClient();
      final session = SessionState(
        midiApi: MidiApi(client),
        audioApi: AudioApi(client),
        syncApi: SyncApi(client),
        scoreApi: ScoreApi(client),
        feedbackApi: FeedbackApi(client),
      );
      session.midiSessionId = 'session-1';

      await session.previewBytesForTrack(2);
      await session.previewBytesForTrack(2);

      expect(client.getBytesCallCount, 1);
    });

    test('uploadMidi() leert den Preview-Cache', () async {
      final client = _FakeApiClient();
      final session = SessionState(
        midiApi: MidiApi(client),
        audioApi: AudioApi(client),
        syncApi: SyncApi(client),
        scoreApi: ScoreApi(client),
        feedbackApi: FeedbackApi(client),
      );
      session.midiSessionId = 'session-1';
      await session.previewBytesForTrack(0);
      expect(session.cachedPreviewBytes(0), isNotNull);

      await session.uploadMidi(Uint8List.fromList([9, 9, 9]), 'song.mid');

      expect(session.cachedPreviewBytes(0), isNull);
    });
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd mobile && flutter test test/session_state_test.dart`
Expected: FAIL to compile — `ApiClient.getBytes` doesn't exist, `SessionState.previewBytesForTrack`/`cachedPreviewBytes` don't exist.

- [ ] **Step 3: Add getBytes to ApiClient**

In `mobile/lib/api/api_client.dart`, add a new method after `get()`:

```dart
  Future<Uint8List> getBytes(String path, {Map<String, String>? query}) async {
    final response = await _http.get(_uri(path, query));
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return response.bodyBytes;
    }
    String detail = 'Unbekannter Fehler (${response.statusCode}).';
    try {
      final decoded = jsonDecode(response.body.isEmpty ? '{}' : response.body);
      if (decoded is Map && decoded['detail'] != null) {
        detail = decoded['detail'].toString();
      }
    } catch (_) {
      // Fehlerantwort war kein JSON - Standardnachricht behalten.
    }
    throw ApiException(response.statusCode, detail);
  }
```

- [ ] **Step 4: Add fetchTrackPreview to MidiApi**

In `mobile/lib/api/midi_api.dart`, add a new method after `getTrackCurve`:

```dart
  Future<Uint8List> fetchTrackPreview(
    String sessionId,
    int trackIndex, {
    int transpose = 0,
  }) {
    return _client.getBytes(
      '/api/midi/$sessionId/track-preview',
      query: {
        'track_index': trackIndex.toString(),
        'transpose': transpose.toString(),
      },
    );
  }
```

- [ ] **Step 5: Add the cache and fetch method to SessionState**

In `mobile/lib/state/session_state.dart`, add a new field near `candidates` (after `List<TrackCandidate> candidates = [];`):

```dart
  final Map<int, Uint8List> _trackPreviewCache = {};
```

Add two new methods anywhere in the class body (e.g. right after `selectTrack`):

```dart
  /// Bereits geladene Vorschau-Bytes fuer einen Track, falls vorhanden - sync,
  /// fuer den Play/Pause-Icon-Status (siehe isPlayingAudio-Identitaetsvergleich).
  Uint8List? cachedPreviewBytes(int trackIndex) => _trackPreviewCache[trackIndex];

  /// Holt die Hoerprobe fuer einen Track lazy und cacht sie; wiederholte Aufrufe
  /// fuer denselben Track loesen keinen erneuten Request aus. Transponierung ist
  /// bewusst nicht beruecksichtigt (Vorschau ist immer in Originaltonlage, hilft
  /// bei der Spurwahl vor dem Transponieren).
  Future<Uint8List> previewBytesForTrack(int trackIndex) async {
    final cached = _trackPreviewCache[trackIndex];
    if (cached != null) return cached;
    final bytes = await midiApi.fetchTrackPreview(midiSessionId!, trackIndex);
    _trackPreviewCache[trackIndex] = bytes;
    return bytes;
  }
```

Then clear the cache in `uploadMidi()`: add `_trackPreviewCache.clear();` right after the existing `candidates = [];` line near the top of `uploadMidi()`.

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd mobile && flutter test test/session_state_test.dart`
Expected: all tests PASS, including the 3 new ones.

- [ ] **Step 7: Run the full mobile test suite for regressions**

Run: `cd mobile && flutter test`
Expected: all tests PASS.

- [ ] **Step 8: Commit**

```bash
git add mobile/lib/api/api_client.dart mobile/lib/api/midi_api.dart mobile/lib/state/session_state.dart mobile/test/session_state_test.dart
git commit -m "feat: fetch and cache per-track audio preview bytes in SessionState"
```

---

### Task 5: Mobile — TrackPreviewButton-Widget + Einbindung in TrackCandidateCard

**Files:**
- Create: `mobile/lib/widgets/track_preview_button.dart`
- Modify: `mobile/lib/widgets/track_candidate_card.dart`
- Test: Create `mobile/test/track_preview_button_test.dart`

**Interfaces:**
- Consumes: `SessionState.cachedPreviewBytes(int)`, `SessionState.previewBytesForTrack(int)` (Task 4), `SessionState.play(Uint8List)`, `SessionState.pause()`, `SessionState.isPlayingAudio(Uint8List?)` (pre-existing).
- Produces: `TrackPreviewButton({required int trackIndex})` widget.

- [ ] **Step 1: Write the failing tests**

Create `mobile/test/track_preview_button_test.dart`:

```dart
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:singing_feedback_mobile/api/api_client.dart';
import 'package:singing_feedback_mobile/api/audio_api.dart';
import 'package:singing_feedback_mobile/api/feedback_api.dart';
import 'package:singing_feedback_mobile/api/midi_api.dart';
import 'package:singing_feedback_mobile/api/score_api.dart';
import 'package:singing_feedback_mobile/api/sync_api.dart';
import 'package:singing_feedback_mobile/state/session_state.dart';
import 'package:singing_feedback_mobile/widgets/track_preview_button.dart';

class _FakePreviewApiClient extends ApiClient {
  _FakePreviewApiClient() : super(baseUrl: 'http://fake.local');

  int getBytesCallCount = 0;
  Object? throwOnGetBytes;

  @override
  Future<Uint8List> getBytes(String path, {Map<String, String>? query}) async {
    getBytesCallCount++;
    if (throwOnGetBytes != null) throw throwOnGetBytes!;
    return Uint8List.fromList([1, 2, 3]);
  }
}

class _FakePlaybackController implements AudioPlaybackController {
  int playCallCount = 0;
  int pauseCallCount = 0;
  final _completeController = StreamController<void>.broadcast();

  @override
  Future<void> play(Uint8List bytes) async {
    playCallCount++;
  }

  @override
  Future<void> playFrom(Uint8List bytes, Duration position) async {}

  @override
  Future<void> pause() async {
    pauseCallCount++;
  }

  @override
  Future<void> stop() async {}

  @override
  Stream<void> get onComplete => _completeController.stream;

  @override
  void dispose() {
    unawaited(_completeController.close());
  }
}

SessionState _buildSession(ApiClient client, AudioPlaybackController fake) {
  return SessionState(
    midiApi: MidiApi(client),
    audioApi: AudioApi(client),
    syncApi: SyncApi(client),
    scoreApi: ScoreApi(client),
    feedbackApi: FeedbackApi(client),
    playbackControllerFactory: () => fake,
  );
}

Widget _wrap(SessionState session, Widget child) {
  return ChangeNotifierProvider<SessionState>.value(
    value: session,
    child: MaterialApp(home: Scaffold(body: child)),
  );
}

void main() {
  group('TrackPreviewButton', () {
    testWidgets('Tap holt die Vorschau und startet die Wiedergabe', (tester) async {
      final client = _FakePreviewApiClient();
      final fake = _FakePlaybackController();
      final session = _buildSession(client, fake);
      session.midiSessionId = 'session-1';

      await tester.pumpWidget(_wrap(session, const TrackPreviewButton(trackIndex: 0)));

      expect(find.byIcon(Icons.play_arrow), findsOneWidget);

      await tester.tap(find.byIcon(Icons.play_arrow));
      await tester.pumpAndSettle();

      expect(client.getBytesCallCount, 1);
      expect(fake.playCallCount, 1);
      expect(find.byIcon(Icons.pause), findsOneWidget);
    });

    testWidgets('zweiter Tap auf denselben Button pausiert statt erneut zu laden',
        (tester) async {
      final client = _FakePreviewApiClient();
      final fake = _FakePlaybackController();
      final session = _buildSession(client, fake);
      session.midiSessionId = 'session-1';

      await tester.pumpWidget(_wrap(session, const TrackPreviewButton(trackIndex: 0)));
      await tester.tap(find.byIcon(Icons.play_arrow));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.pause));
      await tester.pumpAndSettle();

      expect(client.getBytesCallCount, 1);
      expect(fake.pauseCallCount, 1);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    });

    testWidgets('Fehler beim Laden zeigt eine Inline-Fehlermeldung', (tester) async {
      final client = _FakePreviewApiClient()..throwOnGetBytes = Exception('Netzwerkfehler');
      final fake = _FakePlaybackController();
      final session = _buildSession(client, fake);
      session.midiSessionId = 'session-1';

      await tester.pumpWidget(_wrap(session, const TrackPreviewButton(trackIndex: 0)));
      await tester.tap(find.byIcon(Icons.play_arrow));
      await tester.pumpAndSettle();

      expect(find.textContaining('Vorschau fehlgeschlagen'), findsOneWidget);
      expect(fake.playCallCount, 0);
    });

    testWidgets(
        'zwei TrackPreviewButton-Instanzen mit unterschiedlichem trackIndex teilen '
        'sich den Player, zeigen aber unabhaengige Icons', (tester) async {
      final client = _FakePreviewApiClient();
      final fake = _FakePlaybackController();
      final session = _buildSession(client, fake);
      session.midiSessionId = 'session-1';

      await tester.pumpWidget(_wrap(
        session,
        const Column(children: [
          TrackPreviewButton(trackIndex: 0),
          TrackPreviewButton(trackIndex: 1),
        ]),
      ));

      await tester.tap(find.byIcon(Icons.play_arrow).first);
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.pause), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd mobile && flutter test test/track_preview_button_test.dart`
Expected: FAIL to compile — `TrackPreviewButton` doesn't exist yet.

- [ ] **Step 3: Implement TrackPreviewButton**

Create `mobile/lib/widgets/track_preview_button.dart`:

```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/session_state.dart';

/// Hoerprobe (Sinus-Synth) eines MIDI-Spurkandidaten vor der Auswahl. Holt die
/// Vorschau-Bytes lazy beim ersten Tap ueber SessionState.previewBytesForTrack
/// (dort gecacht) und spielt sie ueber den zentralisierten SessionState-Player ab -
/// kein eigener AudioPlayer, gleiches Muster wie PlaybackButton/ShareButton.
class TrackPreviewButton extends StatefulWidget {
  final int trackIndex;

  const TrackPreviewButton({super.key, required this.trackIndex});

  @override
  State<TrackPreviewButton> createState() => _TrackPreviewButtonState();
}

class _TrackPreviewButtonState extends State<TrackPreviewButton> {
  bool _isBusy = false;
  String? _errorMessage;

  Future<void> _toggle(SessionState session) async {
    if (_isBusy) return;
    setState(() {
      _isBusy = true;
      _errorMessage = null;
    });
    try {
      final cached = session.cachedPreviewBytes(widget.trackIndex);
      if (cached != null && session.isPlayingAudio(cached)) {
        await session.pause();
      } else {
        final bytes = await session.previewBytesForTrack(widget.trackIndex);
        if (!mounted) return;
        await session.play(bytes);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = 'Vorschau fehlgeschlagen: $e');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionState>();
    final cached = session.cachedPreviewBytes(widget.trackIndex);
    final isThisPlaying = cached != null && session.isPlayingAudio(cached);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        OutlinedButton.icon(
          onPressed: _isBusy ? null : () => _toggle(session),
          icon: Icon(isThisPlaying ? Icons.pause : Icons.play_arrow),
          label: Text(isThisPlaying ? 'Pause' : 'Anhören'),
        ),
        if (_errorMessage != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              _errorMessage!,
              style: TextStyle(color: Colors.red.shade300, fontSize: 12),
            ),
          ),
      ],
    );
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd mobile && flutter test test/track_preview_button_test.dart`
Expected: all 4 tests PASS.

- [ ] **Step 5: Wire TrackPreviewButton into TrackCandidateCard**

In `mobile/lib/widgets/track_candidate_card.dart`, add the import:

```dart
import 'track_preview_button.dart';
```

Replace the existing trailing `ElevatedButton(...)` block (the one with `child: const Text('Auswählen & anhören')`) with a `Row` containing a renamed select button plus the new preview button:

```dart
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: candidate.noteCount == 0 ? null : onSelect,
                    child: const Text('Auswählen'),
                  ),
                ),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 140),
                  child: TrackPreviewButton(trackIndex: candidate.index),
                ),
              ],
            ),
```

- [ ] **Step 6: Write a layout regression test**

This project has twice caught real `RenderFlex` overflows this way (see `share_button_layout_test.dart`, `playback_button_layout_test.dart`) — the card now has 3 interactive elements in view (badge, select button, preview button) at once. Create `mobile/test/track_candidate_card_layout_test.dart`:

```dart
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:singing_feedback_mobile/api/api_client.dart';
import 'package:singing_feedback_mobile/api/audio_api.dart';
import 'package:singing_feedback_mobile/api/feedback_api.dart';
import 'package:singing_feedback_mobile/api/midi_api.dart';
import 'package:singing_feedback_mobile/api/score_api.dart';
import 'package:singing_feedback_mobile/api/sync_api.dart';
import 'package:singing_feedback_mobile/models/track_candidate.dart';
import 'package:singing_feedback_mobile/state/session_state.dart';
import 'package:singing_feedback_mobile/widgets/track_candidate_card.dart';

class _FailingPreviewApiClient extends ApiClient {
  _FailingPreviewApiClient() : super(baseUrl: 'http://fake.local');

  @override
  Future<Uint8List> getBytes(String path, {Map<String, String>? query}) async {
    throw PlatformException(
      code: 'PREVIEW_ERROR',
      message: 'Die Vorschau konnte auf diesem Geraet nicht geladen werden, '
          'bitte spaeter erneut versuchen.',
    );
  }
}

TrackCandidate _longNameCandidate() {
  return TrackCandidate.fromJson({
    'index': 0,
    'name': 'Eine ziemlich lange Instrumentenspur-Bezeichnung',
    'program': 53,
    'is_drum': false,
    'note_count': 5,
    'pitch_min': 60,
    'pitch_max': 67,
    'pitch_min_name': 'C4',
    'pitch_max_name': 'G4',
    'duration_seconds': 5.0,
    'monophonic': true,
    'name_hint_match': true,
    'plausible': true,
    'score': 82.4,
    'warnings': <String>['Spur ist ueberwiegend polyphon (klingt eher nach Akkorden als nach einer Einzelstimme).'],
  });
}

void main() {
  testWidgets(
      'TrackCandidateCard mit langem Namen, Warnung und Preview-Fehlertext '
      'ueberlaeuft bei 390dp Breite nicht (RenderFlex)', (tester) async {
    final client = _FailingPreviewApiClient();
    final session = SessionState(
      midiApi: MidiApi(client),
      audioApi: AudioApi(client),
      syncApi: SyncApi(client),
      scoreApi: ScoreApi(client),
      feedbackApi: FeedbackApi(client),
    );
    session.midiSessionId = 'session-1';

    await tester.pumpWidget(
      ChangeNotifierProvider<SessionState>.value(
        value: session,
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 390,
              child: TrackCandidateCard(
                candidate: _longNameCandidate(),
                selected: false,
                onSelect: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);

    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('Vorschau fehlgeschlagen'), findsOneWidget);
  });
}
```

- [ ] **Step 7: Run all new/changed mobile tests**

Run: `cd mobile && flutter test test/track_preview_button_test.dart test/track_candidate_card_layout_test.dart test/track_candidate_card_test.dart`
Expected: all PASS. If the layout test finds an overflow, adjust `track_candidate_card.dart` (e.g. wrap the name `Text` in `Expanded` with `overflow: TextOverflow.ellipsis`, already covered since Step 5 wraps it in `Expanded` from Task 3) until it passes — do not weaken the test's width or content to dodge the failure.

- [ ] **Step 8: Run the full mobile test suite for regressions**

Run: `cd mobile && flutter test`
Expected: all tests PASS.

- [ ] **Step 9: Commit**

```bash
git add mobile/lib/widgets/track_preview_button.dart mobile/lib/widgets/track_candidate_card.dart mobile/test/track_preview_button_test.dart mobile/test/track_candidate_card_layout_test.dart
git commit -m "feat: add TrackPreviewButton and wire it into TrackCandidateCard"
```

---

## Self-Review Notes

- **Spec coverage:** Part A (score) → Task 1 + Task 3. Part B (preview) → Task 2 + Task 4 + Task 5. Testing section of the spec → covered per-task. Out-of-scope items (no change to `plausible`/warnings logic, no soundfont, no preview-bytes persistence beyond the session) are respected — no task touches `plausible` computation or introduces file persistence.
- **Type consistency checked:** `TrackCandidate.score` (Dart `double`) ↔ backend `score: float`/JSON number — consistent. `SessionState.previewBytesForTrack`/`cachedPreviewBytes` names match between Task 4 (producer) and Task 5 (consumer). `ApiClient.getBytes` signature matches between Task 4's implementation and Task 5's fakes (which subclass the real `ApiClient` and override it, same pattern as `_FakeApiClient` in `session_state_test.dart`).
- **No placeholders:** every step has literal code, not descriptions.

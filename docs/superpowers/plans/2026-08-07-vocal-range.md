# Stimmumfang der Aufnahme (Phase 4-Rest, Teil 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Report the pitch range of the singer's own recording (min/max sung pitch, percentile-trimmed to ignore outlier frames) as a purely informational summary field — no scoring, no problem tag, no exercise catalog entry.

**Architecture:** A new `backend/scoring/vocal_range.py` module aggregates `sung_curve`'s voiced `hz` values directly — no note segmentation or DTW alignment needed, since pitch values are unaffected by time-alignment. `score.py`'s orchestrator calls it once and adds the result to `summary["vocal_range"]`. Mobile adds a matching `VocalRange` model class and a `ScoreSummaryView` display line, formatting MIDI note numbers into human-readable note names client-side (the scoring engine deliberately has no `pretty_midi` dependency).

**Tech Stack:** Python (backend/scoring), Dart/Flutter (mobile/lib/models, mobile/lib/widgets), pytest, flutter_test.

## Global Constraints

- New backend constants live in `backend/config.py`, following the existing convention (see `GLIDE_ONSET_THRESHOLD_CENTS` etc.).
- No percentile interpolation, no `numpy` — index selection on a sorted list (`round(percentile/100 * (n-1))`), consistent with the rest of the scoring engine's median calculations.
- `confidence` (present on every sung-curve frame) is deliberately NOT used as a filter — no other part of the scoring engine uses it, and this feature shouldn't introduce a new precedent.
- Purely informational: no `problem_tags` entry, no exercise-catalog entry, no effect on `overall_score`.
- No new E2E fixture — unit-level tests via directly-constructed frame dicts, matching the existing test style in `tests/test_scoring.py`.

---

### Task 1: Stimmumfang-Kernlogik (`backend/scoring/vocal_range.py`)

**Files:**
- Modify: `backend/config.py`
- Modify: `backend/scoring/notes.py`
- Create: `backend/scoring/vocal_range.py`
- Test: `tests/test_scoring.py`

**Interfaces:**
- Consumes: nothing new.
- Produces: `hz_to_midi_note(hz: float) -> int` (relocated/extracted, `backend.scoring.notes`) and
  `compute_vocal_range(sung_curve: list[dict]) -> dict` with shape
  `{"applicable": bool, "min_hz": float | None, "max_hz": float | None, "min_midi_note": int | None, "max_midi_note": int | None}`.

- [ ] **Step 1: Add vocal-range constants to config.py**

Append to `backend/config.py`, after the existing `GLIDE_ONSET_THRESHOLD_CENTS = 60.0` line:

```python

# Bewertungs-Engine: Stimmumfang der Aufnahme (Phase 4-Rest, Teil 2) - siehe
# docs/superpowers/specs/2026-08-07-vocal-range-design.md.
VOCAL_RANGE_LOW_PERCENTILE = 5.0
VOCAL_RANGE_HIGH_PERCENTILE = 95.0
VOCAL_RANGE_MIN_VOICED_FRAMES = 10
```

- [ ] **Step 2: Write the failing tests for hz_to_midi_note and compute_vocal_range**

In `tests/test_scoring.py`, add `hz_to_midi_note` to the existing top import line, so it reads:

```python
from backend.scoring.notes import attribute_sung_frames, hz_to_cents, hz_to_midi_note, segment_target_notes
```

Then append this whole block near the end of the file, after the last `test_compute_glide_*` test and before the `from backend.scoring import score_performance` import line:

```python
def test_hz_to_midi_note_reference_a4():
    assert hz_to_midi_note(440.0) == 69


def test_hz_to_midi_note_middle_c():
    assert hz_to_midi_note(261.626) == 60


from backend.scoring.vocal_range import compute_vocal_range


def test_compute_vocal_range_trims_outliers_via_percentile():
    # 100 Frames gleichmaessig zwischen ~220Hz und ~438Hz verteilt, plus 2 extreme
    # Ausreisser (55Hz und 1760Hz, je 2 Oktaven ausserhalb) - die Perzentil-Trimmung
    # (5./95.) darf sie nicht in min_hz/max_hz einfliessen lassen.
    frames = [_sung_frame(round(i * 0.01, 3), 220.0 + i * 2.2, aligned_t=round(i * 0.01, 3)) for i in range(100)]
    frames.append(_sung_frame(1.0, 55.0, aligned_t=1.0))
    frames.append(_sung_frame(1.01, 1760.0, aligned_t=1.01))
    result = compute_vocal_range(frames)
    assert result["applicable"] is True
    assert 200.0 < result["min_hz"] < 240.0
    assert 420.0 < result["max_hz"] < 445.0


def test_compute_vocal_range_not_applicable_with_too_few_frames():
    frames = [_sung_frame(round(i * 0.01, 3), 440.0, aligned_t=round(i * 0.01, 3)) for i in range(5)]
    result = compute_vocal_range(frames)
    assert result["applicable"] is False
    assert result["min_hz"] is None
    assert result["max_hz"] is None
    assert result["min_midi_note"] is None
    assert result["max_midi_note"] is None


def test_compute_vocal_range_not_applicable_when_fully_unvoiced():
    frames = [
        _sung_frame(round(i * 0.01, 3), None, voiced=False, aligned_t=round(i * 0.01, 3))
        for i in range(50)
    ]
    result = compute_vocal_range(frames)
    assert result["applicable"] is False


def test_compute_vocal_range_uniform_pitch_min_equals_max():
    frames = [_sung_frame(round(i * 0.01, 3), 440.0, aligned_t=round(i * 0.01, 3)) for i in range(50)]
    result = compute_vocal_range(frames)
    assert result["applicable"] is True
    assert result["min_hz"] == pytest.approx(440.0)
    assert result["max_hz"] == pytest.approx(440.0)
    assert result["min_midi_note"] == 69
    assert result["max_midi_note"] == 69
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/test_scoring.py -k "hz_to_midi_note or compute_vocal_range" -v`
Expected: FAIL — `hz_to_midi_note` doesn't exist yet in `notes.py`, and `backend.scoring.vocal_range` doesn't exist.

- [ ] **Step 4: Extract hz_to_midi_note in notes.py**

In `backend/scoring/notes.py`, add this function right after `hz_to_cents`:

```python
def hz_to_midi_note(hz: float) -> int:
    return round(69 + 12 * math.log2(hz / 440.0))
```

Then in `segment_target_notes`, replace the existing fallback line:

```python
            midi_note = round(69 + 12 * math.log2(median_hz / 440.0))
```

with:

```python
            midi_note = hz_to_midi_note(median_hz)
```

- [ ] **Step 5: Implement vocal_range.py**

Create `backend/scoring/vocal_range.py`:

```python
"""Stimmumfang der Aufnahme (Phase 4-Rest, Teil 2): rein informative Kennzahl ueber
die ganze gesungene Aufnahme, unabhaengig von Noten-Segmentierung/DTW-Ausrichtung -
Tonhoehe aendert sich durch die Zeitausrichtung nicht, daher genuegt die rohe
sung_curve."""

from __future__ import annotations

from backend.config import (
    VOCAL_RANGE_HIGH_PERCENTILE,
    VOCAL_RANGE_LOW_PERCENTILE,
    VOCAL_RANGE_MIN_VOICED_FRAMES,
)
from backend.scoring.notes import hz_to_midi_note

NOT_APPLICABLE_VOCAL_RANGE = {
    "applicable": False, "min_hz": None, "max_hz": None, "min_midi_note": None, "max_midi_note": None,
}


def compute_vocal_range(sung_curve: list[dict]) -> dict:
    voiced_hz = sorted(
        frame["hz"] for frame in sung_curve
        if frame.get("voiced") and frame.get("hz") is not None
    )
    if len(voiced_hz) < VOCAL_RANGE_MIN_VOICED_FRAMES:
        return dict(NOT_APPLICABLE_VOCAL_RANGE)

    n = len(voiced_hz)
    low_index = round((VOCAL_RANGE_LOW_PERCENTILE / 100) * (n - 1))
    high_index = round((VOCAL_RANGE_HIGH_PERCENTILE / 100) * (n - 1))
    min_hz = voiced_hz[low_index]
    max_hz = voiced_hz[high_index]
    return {
        "applicable": True,
        "min_hz": round(min_hz, 3),
        "max_hz": round(max_hz, 3),
        "min_midi_note": hz_to_midi_note(min_hz),
        "max_midi_note": hz_to_midi_note(max_hz),
    }
```

Note: the not-applicable sentinel is named `NOT_APPLICABLE_VOCAL_RANGE` (public, no leading underscore) from the start — Task 2 imports it directly rather than redefining its own copy (this project's scoring engine previously had two independently-defined copies of the equivalent glide sentinel across two modules, found and fixed as a final-review finding; don't repeat that here).

- [ ] **Step 6: Run tests to verify they pass**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/test_scoring.py -v`
Expected: all tests PASS, including the 6 new ones and every pre-existing test (proves the `hz_to_midi_note` extraction didn't change `segment_target_notes`' behavior).

- [ ] **Step 7: Run the full backend test suite for regressions**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/ -v`
Expected: all tests PASS.

- [ ] **Step 8: Commit**

```bash
git add backend/config.py backend/scoring/notes.py backend/scoring/vocal_range.py tests/test_scoring.py
git commit -m "feat: add compute_vocal_range, extract hz_to_midi_note as a shared helper"
```

---

### Task 2: Integration in score.py (Orchestrator)

**Files:**
- Modify: `backend/scoring/score.py`
- Test: `tests/test_scoring.py`

**Interfaces:**
- Consumes: `compute_vocal_range(sung_curve) -> dict` and `NOT_APPLICABLE_VOCAL_RANGE` from Task 1 (`backend.scoring.vocal_range`).
- Produces: `score_performance()`'s `summary` dict gains a `"vocal_range"` key (same shape as `compute_vocal_range`'s return value).

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_scoring.py`, after the last `test_score_performance_skips_glide_for_timing_flagged_notes` test:

```python
def test_score_performance_includes_vocal_range_in_summary():
    target_curve = [{"t": round(i * 0.01, 3), "hz": 440.0, "midi_note": 69} for i in range(100)]
    sung_curve = [
        _sung_frame(round(i * 0.01, 3), 220.0 + i * 2.2, aligned_t=round(i * 0.01, 3))
        for i in range(100)
    ]
    result = score_performance(target_curve, sung_curve, frame_rate_hz=100.0)
    vocal_range = result["summary"]["vocal_range"]
    assert vocal_range["applicable"] is True
    assert vocal_range["min_hz"] < vocal_range["max_hz"]


def test_score_performance_vocal_range_not_applicable_for_silent_recording():
    target_curve = [{"t": round(i * 0.01, 3), "hz": 440.0, "midi_note": 69} for i in range(100)]
    sung_curve = [
        _sung_frame(round(i * 0.01, 3), None, voiced=False, aligned_t=round(i * 0.01, 3))
        for i in range(100)
    ]
    result = score_performance(target_curve, sung_curve, frame_rate_hz=100.0)
    assert result["summary"]["vocal_range"]["applicable"] is False
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/test_scoring.py -k score_performance_includes_vocal_range -v`
Expected: FAIL with `KeyError: 'vocal_range'`.

- [ ] **Step 3: Wire vocal_range into score.py**

In `backend/scoring/score.py`, add to the imports (after the existing `from backend.scoring.timing import ...` line, keeping alphabetical order):

```python
from backend.scoring.vocal_range import compute_vocal_range
```

Right after the existing `aligned_t` validation block and before `target_notes = segment_target_notes(...)`, add:

```python
    vocal_range = compute_vocal_range(sung_curve)
```

In the `summary` dict literal (the one returned at the end of the function), add `"vocal_range": vocal_range,` right after the existing `"problem_tags": sorted(problem_tags),` line.

- [ ] **Step 4: Run tests to verify they pass**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/test_scoring.py -v`
Expected: all tests PASS, including the 2 new ones.

- [ ] **Step 5: Run the full backend test suite for regressions**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/ -v`
Expected: all tests PASS. In particular `tests/test_e2e_phase4.py` must still pass unchanged — it doesn't assert on `summary["vocal_range"]` at all, so adding a new summary key alongside the existing ones is additive and safe.

- [ ] **Step 6: Commit**

```bash
git add backend/scoring/score.py tests/test_scoring.py
git commit -m "feat: add vocal_range to score_performance's summary output"
```

---

### Task 3: Mobile — VocalRange-Modell + ScoreSummary-Feld

**Files:**
- Modify: `mobile/lib/models/score_result.dart`
- Modify: `mobile/test/score_result_test.dart`
- Modify: `mobile/test/score_summary_view_test.dart`
- Modify: `mobile/test/feedback_section_test.dart`
- Modify: `mobile/test/session_state_test.dart`

**Interfaces:**
- Consumes: backend JSON shape `summary.vocal_range = {"applicable", "min_hz", "max_hz", "min_midi_note", "max_midi_note"}` from Task 2 (this task supplies its own JSON fixtures in tests, no runtime coupling).
- Produces: `VocalRange` class (`applicable: bool`, `minHz: double?`, `maxHz: double?`, `minMidiNote: int?`, `maxMidiNote: int?`, `fromJson`/`toJson`). `ScoreSummary.vocalRange: VocalRange` (new required field, added last).

- [ ] **Step 1: Write the failing test**

In `mobile/test/score_result_test.dart`, add a `'vocal_range'` key to the summary map inside `_resultJson()`. Replace the function:

```dart
Map<String, dynamic> _resultJson() => {
      'notes': [_noteJson()],
      'summary': {
        'note_count': 1, 'missed_count': 0,
        'cents_green': 1, 'cents_yellow': 0, 'cents_red': 0,
        'timing_flagged_count': 0, 'stability_flagged_count': 0,
        'phrase_end_drift_flagged_count': 0,
        'glide_flagged_count': 1,
        'overall_score': 100.0,
        'problem_tags': <String>[],
        'vocal_range': {
          'applicable': true,
          'min_hz': 196.5,
          'max_hz': 587.3,
          'min_midi_note': 55,
          'max_midi_note': 74,
        },
      },
    };
```

(The rest of the file — the round-trip `test(...)` block — stays unchanged.)

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mobile && flutter test test/score_result_test.dart`
Expected: FAIL — `result.toJson()` won't include the `vocal_range` key yet (since `ScoreSummary` doesn't parse or re-emit it), so it won't equal `original`.

- [ ] **Step 3: Add the VocalRange class and wire it into ScoreSummary**

In `mobile/lib/models/score_result.dart`, add this new class right after `ScoreNote`'s closing `}` and before `class ScoreSummary`:

```dart
class VocalRange {
  final bool applicable;
  final double? minHz;
  final double? maxHz;
  final int? minMidiNote;
  final int? maxMidiNote;

  const VocalRange({
    required this.applicable,
    required this.minHz,
    required this.maxHz,
    required this.minMidiNote,
    required this.maxMidiNote,
  });

  factory VocalRange.fromJson(Map<String, dynamic> json) => VocalRange(
        applicable: json['applicable'] as bool,
        minHz: (json['min_hz'] as num?)?.toDouble(),
        maxHz: (json['max_hz'] as num?)?.toDouble(),
        minMidiNote: json['min_midi_note'] as int?,
        maxMidiNote: json['max_midi_note'] as int?,
      );

  Map<String, dynamic> toJson() => {
        'applicable': applicable,
        'min_hz': minHz,
        'max_hz': maxHz,
        'min_midi_note': minMidiNote,
        'max_midi_note': maxMidiNote,
      };
}
```

In `ScoreSummary`, add a new field right after `final List<String> problemTags;`:

```dart
  final VocalRange vocalRange;
```

Add it to the constructor, right after `required this.problemTags,`:

```dart
    required this.vocalRange,
```

In `ScoreSummary.fromJson`, add parsing, right after `problemTags: (json['problem_tags'] as List).cast<String>(),`:

```dart
        vocalRange: VocalRange.fromJson(json['vocal_range'] as Map<String, dynamic>),
```

In `ScoreSummary.toJson()`, add serialization, right after `'problem_tags': problemTags,`:

```dart
        'vocal_range': vocalRange.toJson(),
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mobile && flutter test test/score_result_test.dart`
Expected: PASS.

- [ ] **Step 5: Fix the two other direct ScoreSummary(...) construction sites**

`ScoreSummary` is a required-field constructor, so both other direct construction sites in the test suite need a `vocalRange:` argument now (both currently fail to compile without it).

In `mobile/test/score_summary_view_test.dart`, in `_resultWith()`'s `ScoreSummary(...)` call, add right after `problemTags: [],`:

```dart
      vocalRange: const VocalRange(
        applicable: false,
        minHz: null,
        maxHz: null,
        minMidiNote: null,
        maxMidiNote: null,
      ),
```

In `mobile/test/feedback_section_test.dart`, in `_dummyScoreResult()`'s `ScoreSummary(...)` call, add right after `problemTags: problemTags,`:

```dart
      vocalRange: const VocalRange(
        applicable: false,
        minHz: null,
        maxHz: null,
        minMidiNote: null,
        maxMidiNote: null,
      ),
```

- [ ] **Step 6: Fix the raw JSON fixture in session_state_test.dart**

In `mobile/test/session_state_test.dart`, `_FakeApiClient`'s `postJson` override builds a raw score JSON map. In its `'summary': {...}` block, add right after `'problem_tags': <String>[],`:

```dart
          'vocal_range': {
            'applicable': false,
            'min_hz': null,
            'max_hz': null,
            'min_midi_note': null,
            'max_midi_note': null,
          },
```

Without this, `ScoreSummary.fromJson` would throw `type 'Null' is not a subtype of type 'Map<String, dynamic>'` the first time any test in this file triggers a `score()` call.

- [ ] **Step 7: Run the full mobile test suite for regressions**

Run: `cd mobile && flutter test`
Expected: all tests PASS. Sweep for any other `ScoreSummary(` construction site or raw score JSON fixture you find while running the suite — if a test fails with a missing `vocal_range` key or a missing constructor argument, that's another site needing the same fix as Steps 5/6.

- [ ] **Step 8: Commit**

```bash
git add mobile/lib/models/score_result.dart mobile/test/score_result_test.dart mobile/test/score_summary_view_test.dart mobile/test/feedback_section_test.dart mobile/test/session_state_test.dart
git commit -m "feat: parse and serialize vocal_range in ScoreSummary"
```

---

### Task 4: Mobile — Stimmumfang-Anzeige in ScoreSummaryView

**Files:**
- Modify: `mobile/lib/widgets/score_summary_view.dart`
- Modify: `mobile/test/score_summary_view_test.dart`

**Interfaces:**
- Consumes: `ScoreSummary.vocalRange` from Task 3.
- Produces: top-level function `String midiNoteName(int midiNote)` in `score_summary_view.dart` (exported, used by the test) — no other new public interface, this is the final task in the plan.

- [ ] **Step 1: Write the failing tests**

In `mobile/test/score_summary_view_test.dart`, add a new helper function after `_resultWith()`:

```dart
ScoreResult _resultWithVocalRange(VocalRange vocalRange) {
  return ScoreResult(
    notes: const [],
    summary: ScoreSummary(
      noteCount: 0,
      missedCount: 0,
      centsGreen: 0,
      centsYellow: 0,
      centsRed: 0,
      timingFlaggedCount: 0,
      stabilityFlaggedCount: 0,
      phraseEndDriftFlaggedCount: 0,
      glideFlaggedCount: 0,
      overallScore: 100.0,
      problemTags: const [],
      vocalRange: vocalRange,
    ),
  );
}
```

Add these tests inside the existing `void main() { ... }` block, after the two existing `testWidgets` calls:

```dart
  testWidgets('zeigt Stimmumfang, wenn vocalRange.applicable true ist', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ScoreSummaryView(
          result: _resultWithVocalRange(const VocalRange(
            applicable: true,
            minHz: 196.5,
            maxHz: 587.3,
            minMidiNote: 55,
            maxMidiNote: 74,
          )),
        ),
      ),
    ));
    expect(find.textContaining('Stimmumfang: G3–D5'), findsOneWidget);
  });

  testWidgets('zeigt keinen Stimmumfang-Hinweis, wenn vocalRange.applicable false ist',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ScoreSummaryView(
          result: _resultWithVocalRange(const VocalRange(
            applicable: false,
            minHz: null,
            maxHz: null,
            minMidiNote: null,
            maxMidiNote: null,
          )),
        ),
      ),
    ));
    expect(find.textContaining('Stimmumfang'), findsNothing);
  });

  test('midiNoteName formatiert C4/A4 korrekt', () {
    expect(midiNoteName(60), 'C4');
    expect(midiNoteName(69), 'A4');
  });

  test('midiNoteName behandelt Oktavgrenzen korrekt', () {
    expect(midiNoteName(59), 'B3');
    expect(midiNoteName(72), 'C5');
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd mobile && flutter test test/score_summary_view_test.dart`
Expected: FAIL to compile — `midiNoteName` doesn't exist yet.

- [ ] **Step 3: Implement midiNoteName and the display line**

In `mobile/lib/widgets/score_summary_view.dart`, add near the top of the file, after the imports:

```dart
const _midiNoteNames = [
  'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B',
];

String midiNoteName(int midiNote) {
  final octave = (midiNote ~/ 12) - 1;
  final name = _midiNoteNames[midiNote % 12];
  return '$name$octave';
}
```

In `build()`, add a new item to the `Column`'s `children` list, right after the existing summary `Text(...)` widget (the one showing "X verfehlt · Y gelb · ..."):

```dart
        if (result.summary.vocalRange.applicable)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Stimmumfang: '
              '${midiNoteName(result.summary.vocalRange.minMidiNote!)}'
              '–${midiNoteName(result.summary.vocalRange.maxMidiNote!)}',
            ),
          ),
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd mobile && flutter test test/score_summary_view_test.dart`
Expected: all tests PASS (6 total: 2 pre-existing glide tests + 4 new).

- [ ] **Step 5: Run the full mobile test suite for regressions**

Run: `cd mobile && flutter test`
Expected: all tests PASS.

- [ ] **Step 6: Commit**

```bash
git add mobile/lib/widgets/score_summary_view.dart mobile/test/score_summary_view_test.dart
git commit -m "feat: show vocal range hint in ScoreSummaryView"
```

---

## Self-Review Notes

- **Spec coverage:** Berechnung + Perzentil-Trimmung + `hz_to_midi_note`-Extraktion (Task 1), Integration in `score.py` (Task 2), Mobile-Modell (Task 3), Mobile-Anzeige (Task 4) are all covered. Out-of-scope items from the spec (Pausen/Atemstellen, kein Vergleich gegen Zielmelodie, keine Aenderung an bestehenden Metriken) are untouched by every task.
- **Type consistency checked:** `compute_vocal_range`'s return shape (Task 1) matches exactly what Task 2 stores under `summary["vocal_range"]`; `VocalRange`'s field names/types (Task 3) match the JSON shape both tasks 1-2 produce; `ScoreSummary.vocalRange` (Task 3) is exactly what Task 4's `midiNoteName`/display line consume. `NOT_APPLICABLE_VOCAL_RANGE` is defined once (public, Task 1) and not re-defined anywhere else — avoids repeating the glide feature's duplicated-sentinel mistake, called out explicitly in Task 1 Step 5.
- **No placeholders:** every step has literal code, not descriptions.

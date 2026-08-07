# Glide-Erkennung (Phase 4-Rest, Teil 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect per-note "glides" (sliding into the target pitch instead of hitting it directly) in the scoring engine, surface them through the existing `problem_tags`/Claude-feedback pipeline, and display them in the mobile UI.

**Architecture:** A new `backend/scoring/glides.py` module compares a note's onset (head) window against the rest of the note via median cents-deviation, mirroring the existing `phrase_end_drift` logic in `stability.py` but at the opposite end of the note. `score.py`'s orchestrator gates the call (only for notes that aren't missed and classify green/yellow) and folds the result into the existing per-note JSON/summary/`problem_tags` shape. `backend/feedback/generate.py`/`prompt.py` wire the already-existing `haeufiges_hineingleiten` catalog entry into the category-matcher and prompt-building logic (previously stubbed out with an explicit "not built yet" comment). Mobile mirrors the existing `phrase_end_drift` field pattern in `ScoreNote`/`ScoreSummaryView`.

**Tech Stack:** Python (backend/scoring, backend/feedback), Dart/Flutter (mobile/lib/models, mobile/lib/widgets), pytest, flutter_test.

## Global Constraints

- New backend constants live in `backend/config.py`, following the existing convention (see `DRIFT_FLAG_THRESHOLD_CENTS` etc.).
- Median-based comparisons only (no monotonicity checks) — robust against single-frame pYIN noise, consistent with `stability.py`'s existing approach.
- Glide detection is gated at the orchestrator level in `score.py` (only called for notes that are not `missed` and whose `cents_deviation.classification` is `"green"` or `"yellow"`) — mirrors the existing `timing_classification` gating pattern in the same function.
- No change to `is_missed`/`classify_cents`/timing logic — purely additive.
- No new E2E fixture — the existing 5-note fixture (`tests/fixtures/generate_fixtures.py`) stays untouched; glide scenarios are tested via directly-constructed frame dicts, matching the existing stability/drift test style in `tests/test_scoring.py`.

---

### Task 1: Glide-Erkennung Kernlogik (`backend/scoring/glides.py`)

**Files:**
- Modify: `backend/config.py`
- Modify: `backend/scoring/notes.py`
- Modify: `backend/scoring/stability.py`
- Create: `backend/scoring/glides.py`
- Test: `tests/test_scoring.py`

**Interfaces:**
- Consumes: nothing new.
- Produces: `compute_glide(note: dict, attributed_frames: list[dict]) -> dict` with shape
  `{"applicable": bool, "onset_cents_deviation": float | None, "flag": bool, "direction": "up" | "down" | None}`.
  Also produces `cents_series(note: dict, attributed_frames: list[dict]) -> list[tuple[float, float]]`,
  relocated from `stability.py` to `backend/scoring/notes.py` (now public, no leading underscore) — Task 2 and later tasks may see `stability.py` import it from there.

- [ ] **Step 1: Add glide constants to config.py**

Append to `backend/config.py`, after the existing `DRIFT_FLAG_THRESHOLD_CENTS = 30.0` line:

```python

# Bewertungs-Engine: Glide-Erkennung (Phase 4-Rest, Teil 1) - siehe
# docs/superpowers/specs/2026-08-07-glide-detection-design.md.
GLIDE_HEAD_SECONDS = 0.15
GLIDE_MIN_HEAD_FRAMES = 3
GLIDE_ONSET_THRESHOLD_CENTS = 60.0
```

- [ ] **Step 2: Move `_cents_series` from stability.py into notes.py as a public helper**

In `backend/scoring/notes.py`, add this function after `attribute_sung_frames` (at the end of the file):

```python
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
```

In `backend/scoring/stability.py`:
- Remove the private `_cents_series` function definition (lines 32-42 in the current file).
- Add `cents_series` to the existing `from backend.scoring.notes import hz_to_cents` import line, so it reads:
  ```python
  from backend.scoring.notes import cents_series, hz_to_cents
  ```
- Replace both call sites `_cents_series(note, attributed_frames)` (in `compute_stability` and `compute_phrase_end_drift`) with `cents_series(note, attributed_frames)`.

This is a pure relocation — no behavior change. `_cents_series` was never imported/tested directly (only `compute_stability`/`compute_phrase_end_drift` are), so no existing test references the old name.

- [ ] **Step 3: Run the existing stability/drift tests to confirm the refactor didn't break anything**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/test_scoring.py -k "stability or drift" -v`
Expected: all PASS (same as before the refactor — this step only proves the relocation was behavior-preserving).

- [ ] **Step 4: Write the failing tests for compute_glide**

Append to `tests/test_scoring.py` (after the existing stability/drift tests, before the `from backend.scoring import score_performance` import block):

```python
from backend.scoring.glides import compute_glide


def test_compute_glide_flags_genuine_glide_and_reports_direction():
    # Note 1.0-2.0s, Zielton 440Hz. Kopf-Fenster (1.00-1.15s): 15 Frames bei -80 Cent
    # (deutlich abseits). Rest (1.15-1.99s): 85 Frames exakt auf dem Zielton (sauber
    # gelandet) - klassischer Glide-von-unten.
    note = {"start_t": 1.0, "end_t": 2.0, "hz": 440.0}
    off_pitch_hz = 440.0 * 2 ** (-80 / 1200)
    head_frames = [
        _sung_frame(round(1.0 + i * 0.01, 3), off_pitch_hz, aligned_t=round(1.0 + i * 0.01, 3))
        for i in range(15)
    ]
    rest_frames = [
        _sung_frame(round(1.15 + i * 0.01, 3), 440.0, aligned_t=round(1.15 + i * 0.01, 3))
        for i in range(85)
    ]
    result = compute_glide(note, head_frames + rest_frames)
    assert result["applicable"] is True
    assert result["flag"] is True
    assert result["direction"] == "up"
    assert result["onset_cents_deviation"] == pytest.approx(-80.0, abs=0.1)


def test_compute_glide_does_not_flag_clean_onset():
    # Note 1.0-2.0s, Zielton 440Hz, durchgehend auf dem Zielton - kein Glide.
    note = {"start_t": 1.0, "end_t": 2.0, "hz": 440.0}
    frames = [
        _sung_frame(round(1.0 + i * 0.01, 3), 440.0, aligned_t=round(1.0 + i * 0.01, 3))
        for i in range(100)
    ]
    result = compute_glide(note, frames)
    assert result["applicable"] is True
    assert result["flag"] is False
    assert result["direction"] is None


def test_compute_glide_not_applicable_with_too_few_head_frames():
    # Nur 2 Frames im Kopf-Fenster (< GLIDE_MIN_HEAD_FRAMES=3), obwohl der Rest der
    # Note reichlich Frames hat.
    note = {"start_t": 1.0, "end_t": 2.0, "hz": 440.0}
    off_pitch_hz = 440.0 * 2 ** (-80 / 1200)
    head_frames = [
        _sung_frame(round(1.0 + i * 0.01, 3), off_pitch_hz, aligned_t=round(1.0 + i * 0.01, 3))
        for i in range(2)
    ]
    rest_frames = [
        _sung_frame(round(1.15 + i * 0.01, 3), 440.0, aligned_t=round(1.15 + i * 0.01, 3))
        for i in range(85)
    ]
    result = compute_glide(note, head_frames + rest_frames)
    assert result["applicable"] is False
    assert result["onset_cents_deviation"] is None
    assert result["flag"] is False


def test_compute_glide_not_applicable_when_note_shorter_than_head_window():
    # Note ist nur 0.1s lang (< GLIDE_HEAD_SECONDS=0.15s) - das ganze Notenfenster
    # wird zum Kopf-Fenster, es gibt kein Rest-Fenster zum Vergleichen.
    note = {"start_t": 0.0, "end_t": 0.1, "hz": 440.0}
    off_pitch_hz = 440.0 * 2 ** (-80 / 1200)
    frames = [
        _sung_frame(round(i * 0.01, 3), off_pitch_hz, aligned_t=round(i * 0.01, 3))
        for i in range(8)
    ]
    result = compute_glide(note, frames)
    assert result["applicable"] is False
```

- [ ] **Step 5: Run tests to verify they fail**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/test_scoring.py -k compute_glide -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'backend.scoring.glides'`.

- [ ] **Step 6: Implement glides.py**

Create `backend/scoring/glides.py`:

```python
"""Glide-Erkennung (Phase 4-Rest, Teil 1): rutscht der Gesang zu Beginn einer Note
von einer anderen Tonhoehe in den Zielton, statt ihn direkt zu treffen?

Spiegelbildlich zu stability.py's Phrasenend-Drift: dort wird das letzte Zeitfenster
einer Note gegen deren Hauptteil verglichen, hier das ERSTE Zeitfenster (Kopf) gegen
den REST der Note. Nutzt denselben Median-Vergleich (robust gegen einzelne pYIN-
Ausreisser) wie stability.py.
"""

from __future__ import annotations

from backend.config import (
    CENTS_GREEN_THRESHOLD,
    GLIDE_HEAD_SECONDS,
    GLIDE_MIN_HEAD_FRAMES,
    GLIDE_ONSET_THRESHOLD_CENTS,
)
from backend.scoring.notes import cents_series

_NOT_APPLICABLE_GLIDE = {
    "applicable": False, "onset_cents_deviation": None, "flag": False, "direction": None,
}


def compute_glide(note: dict, attributed_frames: list[dict]) -> dict:
    head_end = min(note["start_t"] + GLIDE_HEAD_SECONDS, note["end_t"])
    series = cents_series(note, attributed_frames)
    head_values = sorted(c for t, c in series if t < head_end)
    rest_values = sorted(c for t, c in series if t >= head_end)
    if len(head_values) < GLIDE_MIN_HEAD_FRAMES or not rest_values:
        return dict(_NOT_APPLICABLE_GLIDE)

    head_median = head_values[len(head_values) // 2]
    rest_median = rest_values[len(rest_values) // 2]
    flag = abs(head_median) > GLIDE_ONSET_THRESHOLD_CENTS and abs(rest_median) <= CENTS_GREEN_THRESHOLD
    direction = ("up" if head_median < 0 else "down") if flag else None
    return {
        "applicable": True,
        "onset_cents_deviation": round(head_median, 1),
        "flag": flag,
        "direction": direction,
    }
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/test_scoring.py -v`
Expected: all tests PASS, including the 4 new `compute_glide` tests and every pre-existing test in the file (proves the `_cents_series`→`cents_series` relocation didn't regress anything).

- [ ] **Step 8: Run the full backend test suite for regressions**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/ -v`
Expected: all tests PASS.

- [ ] **Step 9: Commit**

```bash
git add backend/config.py backend/scoring/notes.py backend/scoring/stability.py backend/scoring/glides.py tests/test_scoring.py
git commit -m "feat: add glide detection (compute_glide), share cents_series between stability.py and glides.py"
```

---

### Task 2: Integration in score.py (Orchestrator)

**Files:**
- Modify: `backend/scoring/score.py`
- Test: `tests/test_scoring.py`

**Interfaces:**
- Consumes: `compute_glide(note, attributed_frames) -> dict` from Task 1 (`backend.scoring.glides`).
- Produces: `score_performance()`'s per-note dict gains a `"glide"` key (same shape as `compute_glide`'s return value); `summary` gains `"glide_flagged_count": int`; `problem_tags` may contain `"haeufiges_hineingleiten"`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_scoring.py`, after the existing `test_score_performance_*` tests (search for `from backend.scoring import score_performance` to find that section):

```python
def test_score_performance_flags_glide_and_adds_problem_tag():
    # Zielnote 1.0s bei 440Hz. Gesang deckt die ganze Note ab: Kopf (0.00-0.15s)
    # deutlich abseits (-80 Cent), Rest (0.15-0.99s) exakt auf dem Zielton -
    # ein klarer, hoerbarer Glide, der insgesamt sauber gelandet ist.
    target_curve = [{"t": round(i * 0.01, 3), "hz": 440.0, "midi_note": 69} for i in range(100)]
    off_pitch_hz = 440.0 * 2 ** (-80 / 1200)
    sung_curve = [
        _sung_frame(round(i * 0.01, 3), off_pitch_hz, aligned_t=round(i * 0.01, 3))
        for i in range(15)
    ] + [
        _sung_frame(round(i * 0.01, 3), 440.0, aligned_t=round(i * 0.01, 3))
        for i in range(15, 99)
    ]
    result = score_performance(target_curve, sung_curve, frame_rate_hz=100.0)
    note = result["notes"][0]
    assert note["missed"] is False
    assert note["glide"]["applicable"] is True
    assert note["glide"]["flag"] is True
    assert note["glide"]["direction"] == "up"
    assert result["summary"]["glide_flagged_count"] == 1
    assert "haeufiges_hineingleiten" in result["summary"]["problem_tags"]


def test_score_performance_skips_glide_for_missed_notes():
    # Zielnote 1.0s. Gesang deckt nur die ersten 0.30s ab (Coverage 30% < 50% ->
    # verfehlt), obwohl die vorhandenen Frames rein rechnerisch wie ein Glide
    # aussehen wuerden (Kopf abseits, kurzer Rest sauber). Das Gating in score.py
    # darf compute_glide() bei einer verfehlten Note gar nicht erst aufrufen.
    target_curve = [{"t": round(i * 0.01, 3), "hz": 440.0, "midi_note": 69} for i in range(100)]
    off_pitch_hz = 440.0 * 2 ** (-80 / 1200)
    sung_curve = [
        _sung_frame(round(i * 0.01, 3), off_pitch_hz, aligned_t=round(i * 0.01, 3))
        for i in range(15)
    ] + [
        _sung_frame(round(i * 0.01, 3), 440.0, aligned_t=round(i * 0.01, 3))
        for i in range(15, 30)
    ]
    result = score_performance(target_curve, sung_curve, frame_rate_hz=100.0)
    note = result["notes"][0]
    assert note["missed"] is True
    assert note["glide"] == {
        "applicable": False, "onset_cents_deviation": None, "flag": False, "direction": None,
    }
    assert result["summary"]["glide_flagged_count"] == 0
    assert "haeufiges_hineingleiten" not in result["summary"]["problem_tags"]
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/test_scoring.py -k score_performance_flags_glide -v`
Expected: FAIL with `KeyError: 'glide'` (the note dict doesn't have that key yet).

- [ ] **Step 3: Wire glide into score.py**

In `backend/scoring/score.py`:

Add to the imports (after the existing `from backend.scoring.notes import ...` line):

```python
from backend.scoring.glides import compute_glide
```

Add a new problem-tag constant, next to the existing ones near the top of the file:

```python
_PROBLEM_TAG_GLIDE = "haeufiges_hineingleiten"
```

Add a not-applicable sentinel next to the other module-level constants:

```python
_GLIDE_NOT_APPLICABLE = {
    "applicable": False, "onset_cents_deviation": None, "flag": False, "direction": None,
}
```

Add `glide_flagged = 0` to the counter initialization line (currently
`missed_count = timing_flagged = stability_flagged = drift_flagged = 0`, becomes:

```python
    missed_count = timing_flagged = stability_flagged = drift_flagged = glide_flagged = 0
```

Inside the `for i, note in enumerate(target_notes):` loop, right after the existing
`stability = compute_stability(note, attributed)` / `drift = compute_phrase_end_drift(note, attributed)`
lines, add:

```python
        glide = (
            compute_glide(note, attributed)
            if not missed and cents and cents["classification"] in ("green", "yellow")
            else dict(_GLIDE_NOT_APPLICABLE)
        )
```

In the `if missed or (cents and cents["classification"] == "red"): ...` block that adds
problem tags and increments counters, add a parallel check right after the existing
`if drift["flag"]:` block:

```python
        if glide["flag"]:
            problem_tags.add(_PROBLEM_TAG_GLIDE)
            glide_flagged += 1
```

In the note dict literal (the `notes.append({...})` call), add `"glide": glide,` right
after the existing `"phrase_end_drift": drift,` line (before `"sung_t": ...`).

In the `summary` dict literal, add `"glide_flagged_count": glide_flagged,` right after
the existing `"phrase_end_drift_flagged_count": drift_flagged,` line.

Update the `penalty` calculation to include the glide weight (same weight as stability/drift, 10):

```python
    penalty = (
        missed_count * 100
        + cents_yellow * 20 + cents_red * 45
        + timing_flagged * 15 + stability_flagged * 10 + drift_flagged * 10 + glide_flagged * 10
    )
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/test_scoring.py -v`
Expected: all tests PASS, including the 2 new `score_performance` tests.

- [ ] **Step 5: Run the full backend test suite for regressions**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/ -v`
Expected: all tests PASS. In particular `tests/test_e2e_phase4.py` (which asserts exact `problem_tags` contents against the shared 5-note fixture) must still pass unchanged — that fixture has no note matching the glide gate's requirements (its notes are either constant-offset, early-onset, or drift-at-tail, none of which produce a glide-shaped head-vs-rest split), so `"haeufiges_hineingleiten"` must NOT appear in its `problem_tags`.

- [ ] **Step 6: Commit**

```bash
git add backend/scoring/score.py tests/test_scoring.py
git commit -m "feat: wire glide detection into score_performance (glide field, problem_tags, overall_score penalty)"
```

---

### Task 3: Phase-6-Anschluss (`backend/feedback/generate.py`, `backend/feedback/prompt.py`)

**Files:**
- Modify: `backend/feedback/generate.py`
- Modify: `backend/feedback/prompt.py`
- Test: `tests/test_feedback.py`

**Interfaces:**
- Consumes: `score_result["notes"][i]["glide"]` shape from Task 2 (`{"applicable", "onset_cents_deviation", "flag", "direction"}`).
- Produces: `_CATEGORY_MATCHERS["haeufiges_hineingleiten"]` now resolves to a real matcher (previously absent); `build_prompt_context()`'s per-note dicts gain `"glide_flag"`/`"glide_direction"` keys; `build_prompt_text()` mentions glide counts and per-note glide status.

- [ ] **Step 1: Write the failing tests**

In `tests/test_feedback.py`, update the shared `_note()` helper to accept glide parameters. Replace the existing helper signature and body:

```python
def _note(
    index: int,
    missed: bool = False,
    cents_classification: str = "green",
    cents_value: float | None = 0.0,
    timing_classification: str = "on_time",
    timing_deviation_ms: float | None = None,
    stability_flag: bool = False,
    drift_flag: bool = False,
    drift_direction: str | None = None,
    glide_flag: bool = False,
    glide_direction: str | None = None,
    sung_t: float | None = None,
) -> dict:
    return {
        "index": index,
        "start_t": index * 1.0,
        "end_t": index * 1.0 + 1.0,
        "target_hz": 440.0,
        "target_midi_note": 69,
        "missed": missed,
        "coverage_fraction": 0.0 if missed else 1.0,
        "cents_deviation": {"value": cents_value, "classification": cents_classification},
        "timing": {"deviation_ms": timing_deviation_ms, "classification": timing_classification},
        "held": False,
        "stability": {"applicable": True, "mad_cents": 0.0, "flag": stability_flag},
        "phrase_end_drift": {
            "applicable": True,
            "drift_cents": 0.0,
            "flag": drift_flag,
            "direction": drift_direction,
        },
        "glide": {
            "applicable": True,
            "onset_cents_deviation": 0.0,
            "flag": glide_flag,
            "direction": glide_direction,
        },
        "sung_t": sung_t,
    }
```

Update `_score_result()` to add a `glide_flagged_count` to the summary. Replace its body:

```python
def _score_result(notes: list[dict]) -> dict:
    return {
        "notes": notes,
        "summary": {
            "note_count": len(notes),
            "missed_count": sum(1 for n in notes if n["missed"]),
            "cents_green": sum(1 for n in notes if n["cents_deviation"]["classification"] == "green"),
            "cents_yellow": sum(1 for n in notes if n["cents_deviation"]["classification"] == "yellow"),
            "cents_red": sum(1 for n in notes if n["cents_deviation"]["classification"] == "red"),
            "timing_flagged_count": sum(1 for n in notes if n["timing"]["classification"] != "on_time"),
            "stability_flagged_count": sum(1 for n in notes if n["stability"]["flag"]),
            "phrase_end_drift_flagged_count": sum(1 for n in notes if n["phrase_end_drift"]["flag"]),
            "glide_flagged_count": sum(1 for n in notes if n["glide"]["flag"]),
            "overall_score": 100.0,
            "problem_tags": [],
        },
    }
```

Update `test_build_prompt_context_filters_out_unflagged_notes` to also cover a glide-flagged note. Replace it with:

```python
def test_build_prompt_context_filters_out_unflagged_notes():
    notes = [
        _note(0),
        _note(1, missed=True),
        _note(2, cents_classification="red", cents_value=120.0),
        _note(3, timing_classification="too_late", timing_deviation_ms=250.0),
        _note(4, stability_flag=True),
        _note(5, drift_flag=True, drift_direction="down"),
        _note(6, glide_flag=True, glide_direction="up"),
    ]
    context = build_prompt_context(_score_result(notes))
    flagged_indices = [n["index"] for n in context["flagged_notes"]]
    assert flagged_indices == [1, 2, 3, 4, 5, 6]
```

Add a new test for the prompt text, right after `test_build_prompt_text_mentions_key_summary_numbers`:

```python
def test_build_prompt_text_mentions_glide():
    notes = [_note(0, glide_flag=True, glide_direction="up")]
    context = build_prompt_context(_score_result(notes))
    text = build_prompt_text(context)
    assert "Hineingleiten in den Zielton: 1 Noten" in text
    assert "rutscht rein (up)" in text
```

Add a new end-to-end-style test proving the previously-missing category matcher now works, right after `test_generate_feedback_gives_different_notes_to_two_points_of_the_same_category`:

```python
def test_generate_feedback_glide_category_resolves_jump_to_t(monkeypatch):
    # Vor dieser Aenderung hatte "haeufiges_hineingleiten" keinen Eintrag in
    # _CATEGORY_MATCHERS - _find_jump_to_t haette hier immer None zurueckgegeben,
    # unabhaengig von sung_t.
    monkeypatch.setattr("backend.feedback.generate.ANTHROPIC_API_KEY", "dummy-key")
    notes = [_note(0, glide_flag=True, glide_direction="up", sung_t=3.5)]
    score_result = _score_result(notes)
    score_result["summary"]["problem_tags"] = ["haeufiges_hineingleiten"]
    fake = _FakeMessagesClient(
        points=[{"problem": "Rutscht in den Ton", "uebung_id": "haeufiges_hineingleiten"}]
    )
    result = generate_feedback(score_result, messages_client_factory=lambda: fake)
    assert result["points"][0]["jump_to_t"] == 3.5
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/test_feedback.py -v`
Expected: `test_build_prompt_text_mentions_glide` and `test_generate_feedback_glide_category_resolves_jump_to_t` FAIL (the first because the summary line/note text doesn't exist yet, the second because `jump_to_t` is `None` instead of `3.5` — no matcher exists yet). The other modified tests (`_note`, `_score_result`, `test_build_prompt_context_filters_out_unflagged_notes`) should already PASS at this point since they only touch data shape, not behavior that depends on the fix.

- [ ] **Step 3: Wire the matcher and prompt text**

In `backend/feedback/generate.py`, add a new matcher function after `_matches_stability`:

```python
def _matches_glide(note: dict) -> bool:
    return note["glide_flag"]
```

Replace the `_CATEGORY_MATCHERS` dict and its preceding comment:

```python
# Bildet dieselbe Bedeutung wie die _PROBLEM_TAG_*-Konstanten in scoring/score.py ab:
# welches Feld einer geflaggten Note (siehe prompt.py::build_prompt_context) macht sie
# zu einem Kandidaten fuer die jeweilige Katalog-Kategorie.
_CATEGORY_MATCHERS: dict[str, Callable[[dict], bool]] = {
    "timingprobleme": _matches_timing,
    "absinkende_phrasenenden": _matches_drift,
    "instabile_lange_toene": _matches_stability,
    "unsaubere_einsaetze": _matches_missed,
    "haeufiges_hineingleiten": _matches_glide,
}
```

In `backend/feedback/prompt.py`, update `build_prompt_context()`'s `is_flagged` condition
(add a new `or` clause) and the `flagged_notes.append({...})` dict:

```python
        is_flagged = (
            note["missed"]
            or note["cents_deviation"]["classification"] == "red"
            or note["timing"]["classification"] != "on_time"
            or note["stability"]["flag"]
            or note["phrase_end_drift"]["flag"]
            or note["glide"]["flag"]
        )
        if is_flagged:
            flagged_notes.append({
                "index": note["index"],
                "missed": note["missed"],
                "cents_classification": note["cents_deviation"]["classification"],
                "cents_value": note["cents_deviation"]["value"],
                "timing_classification": note["timing"]["classification"],
                "timing_deviation_ms": note["timing"]["deviation_ms"],
                "stability_flag": note["stability"]["flag"],
                "phrase_end_drift_flag": note["phrase_end_drift"]["flag"],
                "phrase_end_drift_direction": note["phrase_end_drift"]["direction"],
                "glide_flag": note["glide"]["flag"],
                "glide_direction": note["glide"]["direction"],
                "sung_t": note["sung_t"],
            })
```

In `build_prompt_text()`, add a new summary line right after the existing
`f"- Absinkende Phrasenenden: {summary['phrase_end_drift_flagged_count']} Noten",` line:

```python
        f"- Hineingleiten in den Zielton: {summary['glide_flagged_count']} Noten",
```

And add a new `parts` entry in the per-note loop, right after the existing
`if note["phrase_end_drift_flag"]:` block:

```python
            if note["glide_flag"]:
                parts.append(f"rutscht rein ({note['glide_direction']})")
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/test_feedback.py -v`
Expected: all tests PASS.

- [ ] **Step 5: Run the full backend test suite for regressions**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/ -v`
Expected: all tests PASS.

- [ ] **Step 6: Commit**

```bash
git add backend/feedback/generate.py backend/feedback/prompt.py tests/test_feedback.py
git commit -m "feat: wire haeufiges_hineingleiten into the feedback category matcher and prompt"
```

---

### Task 4: Mobile — ScoreNote/ScoreSummary Glide-Felder

**Files:**
- Modify: `mobile/lib/models/score_result.dart`
- Test: `mobile/test/score_result_test.dart`

**Interfaces:**
- Consumes: backend JSON shape `note["glide"] = {"applicable", "onset_cents_deviation", "flag", "direction"}` and `summary["glide_flagged_count"]` from Task 2/3 (this task only needs the JSON shape, not runtime coupling — it supplies its own fixture in the test).
- Produces: `ScoreNote.glideApplicable: bool`, `ScoreNote.glideOnsetCentsDeviation: double?`, `ScoreNote.glideFlag: bool`, `ScoreNote.glideDirection: String?`; `ScoreSummary.glideFlaggedCount: int`.

- [ ] **Step 1: Write the failing test**

In `mobile/test/score_result_test.dart`, update `_noteJson()` and `_resultJson()` to include glide data. Replace the file's fixture functions:

```dart
Map<String, dynamic> _noteJson() => {
      'index': 0, 'start_t': 0.0, 'end_t': 1.0,
      'target_hz': 440.0, 'target_midi_note': 69,
      'missed': false, 'coverage_fraction': 1.0,
      'cents_deviation': {'value': 1.2, 'classification': 'green'},
      'timing': {'deviation_ms': 4.0, 'classification': 'on_time'},
      'held': true,
      'stability': {'applicable': true, 'mad_cents': 0.8, 'flag': false},
      'phrase_end_drift': {'applicable': true, 'drift_cents': 0.3, 'flag': false, 'direction': null},
      'glide': {'applicable': true, 'onset_cents_deviation': -62.0, 'flag': true, 'direction': 'up'},
      'sung_t': 0.12,
    };

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
      },
    };
```

(The rest of the file — the `main()`/`test(...)` block — stays unchanged; it already round-trips whatever `_resultJson()` returns.)

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mobile && flutter test test/score_result_test.dart`
Expected: FAIL — `result.toJson()` won't include the `glide` key (since `ScoreNote` doesn't parse or re-emit it yet), so it won't equal `original`.

- [ ] **Step 3: Add glide fields to ScoreNote and ScoreSummary**

In `mobile/lib/models/score_result.dart`:

Add four new fields to `ScoreNote`, right after `final String? driftDirection;`:

```dart
  final bool glideApplicable;
  final double? glideOnsetCentsDeviation;
  final bool glideFlag;
  final String? glideDirection;
```

Add them as required constructor parameters, right after `required this.driftDirection,`:

```dart
    required this.glideApplicable,
    required this.glideOnsetCentsDeviation,
    required this.glideFlag,
    required this.glideDirection,
```

In `ScoreNote.fromJson`, add parsing right after the existing `final drift = json['phrase_end_drift'] as Map<String, dynamic>;` line:

```dart
    final glide = json['glide'] as Map<String, dynamic>;
```

And add the corresponding fields to the `ScoreNote(...)` constructor call, right after `driftDirection: drift['direction'] as String?,`:

```dart
      glideApplicable: glide['applicable'] as bool,
      glideOnsetCentsDeviation: (glide['onset_cents_deviation'] as num?)?.toDouble(),
      glideFlag: glide['flag'] as bool,
      glideDirection: glide['direction'] as String?,
```

In `ScoreNote.toJson()`, add a new entry to the returned map, right after the existing
`'phrase_end_drift': {...},` block:

```dart
        'glide': {
          'applicable': glideApplicable,
          'onset_cents_deviation': glideOnsetCentsDeviation,
          'flag': glideFlag,
          'direction': glideDirection,
        },
```

Add one new field to `ScoreSummary`, right after `final int phraseEndDriftFlaggedCount;`:

```dart
  final int glideFlaggedCount;
```

Add it to the constructor, right after `required this.phraseEndDriftFlaggedCount,`:

```dart
    required this.glideFlaggedCount,
```

Add it to `ScoreSummary.fromJson`, right after `phraseEndDriftFlaggedCount: json['phrase_end_drift_flagged_count'] as int,`:

```dart
        glideFlaggedCount: json['glide_flagged_count'] as int,
```

Add it to `ScoreSummary.toJson()`, right after `'phrase_end_drift_flagged_count': phraseEndDriftFlaggedCount,`:

```dart
        'glide_flagged_count': glideFlaggedCount,
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mobile && flutter test test/score_result_test.dart`
Expected: PASS.

- [ ] **Step 5: Run the full mobile test suite for regressions**

Run: `cd mobile && flutter test`
Expected: all tests PASS. (Confirm no other file constructs `ScoreNote`/`ScoreSummary` directly with positional/named args that would break on the new required fields — only `ScoreNote.fromJson`/`ScoreSummary.fromJson` are used elsewhere in the codebase, per the existing pattern for this class.)

- [ ] **Step 6: Commit**

```bash
git add mobile/lib/models/score_result.dart mobile/test/score_result_test.dart
git commit -m "feat: parse and serialize glide fields in ScoreNote/ScoreSummary"
```

---

### Task 5: Mobile — Glide-Anzeige in ScoreSummaryView

**Files:**
- Modify: `mobile/lib/widgets/score_summary_view.dart`
- Test: Create `mobile/test/score_summary_view_test.dart`

**Interfaces:**
- Consumes: `ScoreNote.glideFlag`/`ScoreNote.glideDirection` from Task 4.
- Produces: no new public interface — this is the final, UI-facing task.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/score_summary_view_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singing_feedback_mobile/models/score_result.dart';
import 'package:singing_feedback_mobile/widgets/score_summary_view.dart';

ScoreNote _glideNote({required String direction}) {
  return ScoreNote(
    index: 0,
    startT: 0.0,
    endT: 1.0,
    targetHz: 440.0,
    targetMidiNote: 69,
    missed: false,
    coverageFraction: 1.0,
    centsValue: 2.0,
    centsClassification: 'green',
    timingDeviationMs: 4.0,
    timingClassification: 'on_time',
    held: true,
    stabilityApplicable: true,
    stabilityMadCents: 0.5,
    stabilityFlag: false,
    driftApplicable: true,
    driftCents: 0.2,
    phraseEndDriftFlag: false,
    driftDirection: null,
    glideApplicable: true,
    glideOnsetCentsDeviation: -62.0,
    glideFlag: true,
    glideDirection: direction,
    sungT: 0.1,
  );
}

ScoreResult _resultWith(ScoreNote note) {
  return ScoreResult(
    notes: [note],
    summary: const ScoreSummary(
      noteCount: 1,
      missedCount: 0,
      centsGreen: 1,
      centsYellow: 0,
      centsRed: 0,
      timingFlaggedCount: 0,
      stabilityFlaggedCount: 0,
      phraseEndDriftFlaggedCount: 0,
      glideFlaggedCount: 1,
      overallScore: 100.0,
      problemTags: [],
    ),
  );
}

void main() {
  testWidgets('zeigt "gerutscht (von unten)" fuer eine Note mit Glide von unten',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ScoreSummaryView(result: _resultWith(_glideNote(direction: 'up')))),
    ));
    expect(find.textContaining('gerutscht (von unten)'), findsOneWidget);
  });

  testWidgets('zeigt "gerutscht (von oben)" fuer eine Note mit Glide von oben',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ScoreSummaryView(result: _resultWith(_glideNote(direction: 'down')))),
    ));
    expect(find.textContaining('gerutscht (von oben)'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mobile && flutter test test/score_summary_view_test.dart`
Expected: FAIL — `find.textContaining('gerutscht...')` finds nothing (the widget doesn't render glide text yet).

- [ ] **Step 3: Add glide text to ScoreSummaryView**

In `mobile/lib/widgets/score_summary_view.dart`, in `_noteLabel()`, add a new block right
after the existing `if (note.phraseEndDriftFlag) { ... }` block and before
`if (note.stabilityFlag) parts.add('instabil');`:

```dart
    if (note.glideFlag) {
      final direction = note.glideDirection == 'up' ? 'von unten' : 'von oben';
      parts.add('gerutscht ($direction)');
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mobile && flutter test test/score_summary_view_test.dart`
Expected: both tests PASS.

- [ ] **Step 5: Run the full mobile test suite for regressions**

Run: `cd mobile && flutter test`
Expected: all tests PASS.

- [ ] **Step 6: Commit**

```bash
git add mobile/lib/widgets/score_summary_view.dart mobile/test/score_summary_view_test.dart
git commit -m "feat: show glide hint in ScoreSummaryView"
```

---

## Self-Review Notes

- **Spec coverage:** "Erkennung" (Task 1), "Integration in score.py" incl. gating/problem_tags/overall_score (Task 2), "Phase-6-Anschluss" (Task 3), "Mobile" model + display (Task 4 + 5), `_cents_series`→`cents_series` relocation (Task 1 Step 2) are all covered. Out-of-scope items from the spec (Stimmumfang, Pausen/Atemstellen, chart color overlay, changes to `is_missed`/`classify_cents`/timing) are untouched by every task.
- **Type consistency checked:** `compute_glide`'s return shape (Task 1) matches exactly what Task 2 expects to store under `note["glide"]` and what Task 2's `_GLIDE_NOT_APPLICABLE` fallback mirrors; `note["glide"]["flag"]`/`note["glide"]["direction"]` (Task 2's JSON output) match what Task 3's `_matches_glide`/`build_prompt_context` read; `glide_flagged_count` (Task 2) matches what Task 3's `_score_result` test helper and `build_prompt_text` read, and what Task 4's `ScoreSummary.glideFlaggedCount` parses from the same JSON key.
- **No placeholders:** every step has literal code, not descriptions.

# Pausen/Atemstellen-Erkennung (Phase 4-Rest, Teil 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect unexpected (Atem-)Pausen mid-way through a held target note — a
contiguous unvoiced run inside the note's body that exceeds a minimum duration — surface
them through the existing `problem_tags`/Claude-feedback pipeline, and display them in
the mobile UI.

**Architecture:** A new `backend/scoring/pauses.py` module scans a held note's
attributed sung frames (after excluding the same onset-trim window `stability.py` uses)
for the longest contiguous run of unvoiced frames (`voiced=False` or `hz is None`) and
flags it if that run exceeds `PAUSE_MIN_GAP_SECONDS`. `score.py`'s orchestrator gates the
call (only for notes that aren't `missed` — a fully-missed note's huge unvoiced gap is
not a "pause", it's simply an unsung note) and folds the result into the existing
per-note JSON/summary/`problem_tags` shape. A brand-new catalog entry
(`unerwartete_pause_in_gehaltener_note`) is added to `backend/exercises/catalog.yaml`
(unlike Glides, there is no pre-existing stub for this feature) and wired into
`backend/feedback/generate.py`/`prompt.py`. Mobile mirrors the existing
`stability`/`glide` field pattern in `ScoreNote`/`ScoreSummaryView`.

**Tech Stack:** Python (backend/scoring, backend/feedback), Dart/Flutter
(mobile/lib/models, mobile/lib/widgets), pytest, flutter_test.

## Global Constraints

- New backend constant lives in `backend/config.py`, following the existing convention
  (see `GLIDE_HEAD_SECONDS` etc.) — `PAUSE_MIN_GAP_SECONDS = 0.25` (fixed duration, not
  relative to note length, per the approved design spec).
- Pause detection only applies to held notes (`is_held_note()`, reused from
  `stability.py`, not duplicated) and only within `[note.start_t +
  STABILITY_ONSET_TRIM_SECONDS, note.end_t)` — the same onset-trim window
  `stability.py`/`compute_stability` already uses, so a normal consonant attack
  ("T"/"K") at the very start of a note is not mistaken for a pause.
- Gated at the orchestrator level in `score.py`: `compute_pause()` is only called for
  notes that are **not** `missed`. Unlike Glide, the cents/timing classification play no
  role in this gate — pause detection looks at the note's body, not its onset, so the
  DTW-boundary-smearing risk that motivated Glide's extra `timing_classification ==
  "on_time"` clause does not apply here (see
  `docs/superpowers/specs/2026-08-08-pausen-atemstellen-design.md`).
- No change to `is_missed`/`classify_cents`/timing logic — purely additive.
- Out of scope (do not implement): missed breathing opportunities at target rests
  (singer sings through a real target-melody gap without breathing), any chart
  visualization of pauses, and any change to `is_held_note`'s definition itself.
- No new E2E fixture — the existing 5-note fixture (`tests/fixtures/generate_fixtures.py`)
  stays untouched; pause scenarios are tested via directly-constructed frame dicts,
  matching the existing stability/drift/glide test style in `tests/test_scoring.py`.

---

### Task 1: Pausen-Erkennung Kernlogik (`backend/scoring/pauses.py`)

**Files:**
- Modify: `backend/config.py`
- Create: `backend/scoring/pauses.py`
- Test: `tests/test_scoring.py`

**Interfaces:**
- Consumes: `is_held_note(note: dict) -> bool` from `backend.scoring.stability` (already
  exists, unchanged).
- Produces: `compute_pause(note: dict, attributed_frames: list[dict]) -> dict` with shape
  `{"applicable": bool, "gap_seconds": float | None, "flag": bool}`. Also exports
  `NOT_APPLICABLE_PAUSE = {"applicable": False, "gap_seconds": None, "flag": False}`
  (module-level constant, same public-sentinel pattern as `glides.py`'s
  `NOT_APPLICABLE_GLIDE`) for Task 2 to reuse as the gated-off default.

- [ ] **Step 1: Add the pause constant to config.py**

Append to `backend/config.py`, after the existing `GLIDE_ONSET_THRESHOLD_CENTS = 60.0`
line:

```python

# Bewertungs-Engine: Pausen/Atemstellen-Erkennung (Phase 4-Rest, Teil 3) - siehe
# docs/superpowers/specs/2026-08-08-pausen-atemstellen-design.md.
PAUSE_MIN_GAP_SECONDS = 0.25
```

- [ ] **Step 2: Write the failing tests for compute_pause**

Append to `tests/test_scoring.py`, after the existing `test_compute_glide_*` tests
(search for `def test_compute_glide_not_applicable_when_note_shorter_than_head_window`
to find the end of that block):

```python
from backend.scoring.pauses import compute_pause


def test_compute_pause_flags_genuine_gap_in_held_note():
    # Gehaltene Note 1.0-3.0s (2s, ueber HELD_NOTE_MIN_DURATION_SECONDS=0.6s).
    # Betrachtetes Fenster beginnt bei 1.05s (Onset-Trim). Stimmhaft bis 1.50s, dann
    # eine 0.29s lange unstimmhafte Luecke (ueber PAUSE_MIN_GAP_SECONDS=0.25s), danach
    # wieder stimmhaft bis zum Notenende.
    note = {"start_t": 1.0, "end_t": 3.0, "hz": 440.0}
    voiced_before = [
        _sung_frame(round(1.05 + i * 0.01, 3), 440.0, aligned_t=round(1.05 + i * 0.01, 3))
        for i in range(45)
    ]
    gap_frames = [
        _sung_frame(round(1.50 + i * 0.01, 3), None, voiced=False, aligned_t=round(1.50 + i * 0.01, 3))
        for i in range(30)
    ]
    voiced_after = [
        _sung_frame(round(1.80 + i * 0.01, 3), 440.0, aligned_t=round(1.80 + i * 0.01, 3))
        for i in range(100)
    ]
    result = compute_pause(note, voiced_before + gap_frames + voiced_after)
    assert result["applicable"] is True
    assert result["flag"] is True
    assert result["gap_seconds"] == pytest.approx(0.29, abs=0.01)


def test_compute_pause_does_not_flag_short_gap():
    # Gleiche Note, aber die Luecke ist nur 0.1s lang - unter der Schwelle.
    note = {"start_t": 1.0, "end_t": 3.0, "hz": 440.0}
    voiced_before = [
        _sung_frame(round(1.05 + i * 0.01, 3), 440.0, aligned_t=round(1.05 + i * 0.01, 3))
        for i in range(45)
    ]
    gap_frames = [
        _sung_frame(round(1.50 + i * 0.01, 3), None, voiced=False, aligned_t=round(1.50 + i * 0.01, 3))
        for i in range(10)
    ]
    voiced_after = [
        _sung_frame(round(1.60 + i * 0.01, 3), 440.0, aligned_t=round(1.60 + i * 0.01, 3))
        for i in range(100)
    ]
    result = compute_pause(note, voiced_before + gap_frames + voiced_after)
    assert result["applicable"] is True
    assert result["flag"] is False
    assert result["gap_seconds"] == pytest.approx(0.09, abs=0.01)


def test_compute_pause_not_applicable_for_short_note():
    # Nicht gehaltene Note (< HELD_NOTE_MIN_DURATION_SECONDS=0.6s).
    note = {"start_t": 0.0, "end_t": 0.3, "hz": 440.0}
    result = compute_pause(note, [])
    assert result["applicable"] is False
    assert result["gap_seconds"] is None
    assert result["flag"] is False


def test_compute_pause_not_applicable_without_frames_in_window():
    # Gehaltene Note, aber alle Frames liegen VOR dem Onset-Trim-Fenster (< start_t +
    # STABILITY_ONSET_TRIM_SECONDS) - nach dem Trim bleibt nichts uebrig.
    note = {"start_t": 1.0, "end_t": 2.0, "hz": 440.0}
    frames = [_sung_frame(1.0, 440.0, aligned_t=1.0)]
    result = compute_pause(note, frames)
    assert result["applicable"] is False


def test_compute_pause_excludes_onset_trim_window():
    # Der allererste Notenanfang (0.00-0.04s, VOR dem Trim-Fenster bei 0.05s) ist
    # unstimmhaft (z.B. Konsonanten-Einsatz "T") - danach durchgehend stimmhaft. Ohne
    # den Onset-Trim wuerde diese kurze Luecke evtl. mitgezaehlt (hier zu kurz, um die
    # Schwelle zu reissen, aber der Test soll sicherstellen, dass sie erst gar nicht
    # als Luecke im betrachteten Fenster erscheint - alle Frames im Fenster sind
    # stimmhaft, gap_seconds muss 0.0 sein, nicht die Dauer der VOR dem Fenster
    # liegenden Konsonanten-Luecke).
    note = {"start_t": 0.0, "end_t": 1.0, "hz": 440.0}
    onset_gap = [
        _sung_frame(round(i * 0.01, 3), None, voiced=False, aligned_t=round(i * 0.01, 3))
        for i in range(4)
    ]
    voiced = [
        _sung_frame(round(0.05 + i * 0.01, 3), 440.0, aligned_t=round(0.05 + i * 0.01, 3))
        for i in range(90)
    ]
    result = compute_pause(note, onset_gap + voiced)
    assert result["applicable"] is True
    assert result["flag"] is False
    assert result["gap_seconds"] == pytest.approx(0.0, abs=0.001)
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/test_scoring.py -k compute_pause -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'backend.scoring.pauses'`.

- [ ] **Step 4: Implement pauses.py**

Create `backend/scoring/pauses.py`:

```python
"""Pausen/Atemstellen-Erkennung (Phase 4-Rest, Teil 3): macht der Gesang mitten in
einer gehaltenen Zielnote eine (Atem-)Pause, obwohl die Zielmelodie dort keine Pause
vorsieht?

Nutzt dieselben Bausteine wie stability.py: is_held_note()-Gate und
STABILITY_ONSET_TRIM_SECONDS (schliesst den kurzen Konsonanten-Anlauf einer Note aus,
damit ein normaler Wortanlaut wie "T"/"K" nicht faelschlich als Pause zaehlt). Anders
als notes.py's cents_series() filtert diese Funktion NICHT auf stimmhafte Frames - hier
wird gerade nach den unstimmhaften Laeufen gesucht, die cents_series() verwirft.
"""

from __future__ import annotations

from backend.config import PAUSE_MIN_GAP_SECONDS, STABILITY_ONSET_TRIM_SECONDS
from backend.scoring.stability import is_held_note

NOT_APPLICABLE_PAUSE = {"applicable": False, "gap_seconds": None, "flag": False}


def compute_pause(note: dict, attributed_frames: list[dict]) -> dict:
    if not is_held_note(note):
        return dict(NOT_APPLICABLE_PAUSE)

    window_start = note["start_t"] + STABILITY_ONSET_TRIM_SECONDS
    window_end = note["end_t"]
    frames = sorted(
        (
            f for f in attributed_frames
            if f.get("aligned_t") is not None and window_start <= f["aligned_t"] < window_end
        ),
        key=lambda f: f["aligned_t"],
    )
    if not frames:
        return dict(NOT_APPLICABLE_PAUSE)

    longest_gap = 0.0
    run_start = None
    run_end = None
    for frame in frames:
        t = frame["aligned_t"]
        unvoiced = not frame.get("voiced") or frame.get("hz") is None
        if unvoiced:
            if run_start is None:
                run_start = t
            run_end = t
        elif run_start is not None:
            longest_gap = max(longest_gap, run_end - run_start)
            run_start = None
    if run_start is not None:
        longest_gap = max(longest_gap, run_end - run_start)

    return {
        "applicable": True,
        "gap_seconds": round(longest_gap, 3),
        "flag": longest_gap > PAUSE_MIN_GAP_SECONDS,
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/test_scoring.py -v`
Expected: all tests PASS, including the 5 new `compute_pause` tests and every
pre-existing test in the file.

- [ ] **Step 6: Run the full backend test suite for regressions**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/ -v`
Expected: all tests PASS.

- [ ] **Step 7: Commit**

```bash
git add backend/config.py backend/scoring/pauses.py tests/test_scoring.py
git commit -m "feat: add pause detection (compute_pause) for gaps inside held notes"
```

---

### Task 2: Integration in score.py (Orchestrator)

**Files:**
- Modify: `backend/scoring/score.py`
- Test: `tests/test_scoring.py`

**Interfaces:**
- Consumes: `compute_pause(note, attributed_frames) -> dict` and `NOT_APPLICABLE_PAUSE`
  from Task 1 (`backend.scoring.pauses`).
- Produces: `score_performance()`'s per-note dict gains a `"pause"` key (same shape as
  `compute_pause`'s return value); `summary` gains `"pause_flagged_count": int`;
  `problem_tags` may contain `"unerwartete_pause_in_gehaltener_note"`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_scoring.py`, after the existing `test_score_performance_*` tests
(search for `def test_score_performance_skips_glide_for_missed_notes` to find the end of
that block):

```python
def test_score_performance_flags_pause_and_adds_problem_tag():
    # Zielnote 3.0s bei 440Hz (gehalten). Gesang deckt die ganze Note ab, mit einer
    # 0.4s langen unstimmhaften Luecke in der Mitte - eine klare, hoerbare Pause
    # mitten in der gehaltenen Note.
    target_curve = [{"t": round(i * 0.01, 3), "hz": 440.0, "midi_note": 69} for i in range(300)]
    voiced_before = [
        _sung_frame(round(0.05 + i * 0.01, 3), 440.0, aligned_t=round(0.05 + i * 0.01, 3))
        for i in range(95)
    ]
    gap_frames = [
        _sung_frame(round(1.00 + i * 0.01, 3), None, voiced=False, aligned_t=round(1.00 + i * 0.01, 3))
        for i in range(40)
    ]
    voiced_after = [
        _sung_frame(round(1.40 + i * 0.01, 3), 440.0, aligned_t=round(1.40 + i * 0.01, 3))
        for i in range(160)
    ]
    sung_curve = voiced_before + gap_frames + voiced_after
    result = score_performance(target_curve, sung_curve, frame_rate_hz=100.0)
    note = result["notes"][0]
    assert note["missed"] is False
    assert note["pause"]["applicable"] is True
    assert note["pause"]["flag"] is True
    assert result["summary"]["pause_flagged_count"] == 1
    assert "unerwartete_pause_in_gehaltener_note" in result["summary"]["problem_tags"]


def test_score_performance_skips_pause_for_missed_notes():
    # Zielnote 3.0s. Gesang deckt nur die ersten 0.30s ab (Coverage ca. 8% -> verfehlt),
    # der Rest der Note ist komplett unstimmhaft - rein rechnerisch eine riesige
    # "Luecke", aber das Gating in score.py darf compute_pause() bei einer verfehlten
    # Note gar nicht erst aufrufen.
    target_curve = [{"t": round(i * 0.01, 3), "hz": 440.0, "midi_note": 69} for i in range(300)]
    sung_curve = [
        _sung_frame(round(0.05 + i * 0.01, 3), 440.0, aligned_t=round(0.05 + i * 0.01, 3))
        for i in range(25)
    ]
    result = score_performance(target_curve, sung_curve, frame_rate_hz=100.0)
    note = result["notes"][0]
    assert note["missed"] is True
    assert note["pause"] == {"applicable": False, "gap_seconds": None, "flag": False}
    assert result["summary"]["pause_flagged_count"] == 0
    assert "unerwartete_pause_in_gehaltener_note" not in result["summary"]["problem_tags"]
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/test_scoring.py -k score_performance_flags_pause -v`
Expected: FAIL with `KeyError: 'pause'` (the note dict doesn't have that key yet).

- [ ] **Step 3: Wire pause detection into score.py**

In `backend/scoring/score.py`:

Add to the imports, right after the existing
`from backend.scoring.glides import NOT_APPLICABLE_GLIDE, compute_glide` line:

```python
from backend.scoring.pauses import NOT_APPLICABLE_PAUSE, compute_pause
```

Add a new problem-tag constant, right after the existing
`_PROBLEM_TAG_GLIDE = "haeufiges_hineingleiten"` line:

```python
_PROBLEM_TAG_PAUSE = "unerwartete_pause_in_gehaltener_note"
```

Change the counter initialization line from:

```python
    missed_count = timing_flagged = stability_flagged = drift_flagged = glide_flagged = 0
```

to:

```python
    missed_count = timing_flagged = stability_flagged = drift_flagged = glide_flagged = pause_flagged = 0
```

Right after the existing `glide = (...)` block (the multi-line assignment ending
`else dict(NOT_APPLICABLE_GLIDE)`), add:

```python
        pause = compute_pause(note, attributed) if not missed else dict(NOT_APPLICABLE_PAUSE)
```

Right after the existing `if glide["flag"]: problem_tags.add(_PROBLEM_TAG_GLIDE);
glide_flagged += 1` block, add:

```python
        if pause["flag"]:
            problem_tags.add(_PROBLEM_TAG_PAUSE)
            pause_flagged += 1
```

In the note dict literal (the `notes.append({...})` call), add `"pause": pause,` right
after the existing `"glide": glide,` line (before `"sung_t": ...`).

In the `summary` dict literal, add `"pause_flagged_count": pause_flagged,` right after
the existing `"glide_flagged_count": glide_flagged,` line.

Update the `penalty` calculation to include the pause weight (same weight as
stability/drift/glide, 10):

```python
    penalty = (
        missed_count * 100
        + cents_yellow * 20 + cents_red * 45
        + timing_flagged * 15 + stability_flagged * 10 + drift_flagged * 10
        + glide_flagged * 10 + pause_flagged * 10
    )
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/test_scoring.py -v`
Expected: all tests PASS, including the 2 new `score_performance` tests.

- [ ] **Step 5: Run the full backend test suite for regressions**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/ -v`
Expected: all tests PASS. In particular `tests/test_e2e_phase4.py` (which asserts exact
`problem_tags` contents against the shared 5-note fixture) must still pass unchanged —
none of that fixture's notes have a >0.25s unvoiced gap inside their held-note body, so
`"unerwartete_pause_in_gehaltener_note"` must NOT appear in its `problem_tags`.

- [ ] **Step 6: Commit**

```bash
git add backend/scoring/score.py tests/test_scoring.py
git commit -m "feat: wire pause detection into score_performance (pause field, problem_tags, overall_score penalty)"
```

---

### Task 3: Katalog-Eintrag & Phase-6-Anschluss (`backend/exercises/catalog.yaml`, `backend/feedback/generate.py`, `backend/feedback/prompt.py`)

**Files:**
- Modify: `backend/exercises/catalog.yaml`
- Modify: `backend/feedback/generate.py`
- Modify: `backend/feedback/prompt.py`
- Test: `tests/test_feedback.py`

**Interfaces:**
- Consumes: `score_result["notes"][i]["pause"]` shape from Task 2 (`{"applicable",
  "gap_seconds", "flag"}`).
- Produces: `_CATEGORY_MATCHERS["unerwartete_pause_in_gehaltener_note"]` now resolves to
  a real matcher (this catalog id did not exist anywhere before this task);
  `build_prompt_context()`'s per-note dicts gain a `"pause_flag"` key; `build_prompt_text()`
  mentions pause counts and per-note pause status.

- [ ] **Step 1: Add the catalog entry**

Append to `backend/exercises/catalog.yaml`, after the existing `timingprobleme` entry
(the last entry in the file):

```yaml
- id: unerwartete_pause_in_gehaltener_note
  problem: Unerwartete Pause/Atemholen mitten in einer gehaltenen Note
  technik: Atemplanung vor der Phrase statt spontan mitten im Ton
  uebung: Phrase vorher markieren, wo Luft geholt wird, und gezielt nur dort atmen
```

- [ ] **Step 2: Write the failing tests**

In `tests/test_feedback.py`, update the shared `_note()` helper to accept a pause
parameter. Replace the existing helper signature and body:

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
    pause_flag: bool = False,
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
        "pause": {"applicable": True, "gap_seconds": 0.0, "flag": pause_flag},
        "sung_t": sung_t,
    }
```

Update `_score_result()` to add a `pause_flagged_count` to the summary. Replace its
body:

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
            "pause_flagged_count": sum(1 for n in notes if n["pause"]["flag"]),
            "overall_score": 100.0,
            "problem_tags": [],
        },
    }
```

Update `test_build_prompt_context_filters_out_unflagged_notes` to also cover a
pause-flagged note. Replace it with:

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
        _note(7, pause_flag=True),
    ]
    context = build_prompt_context(_score_result(notes))
    flagged_indices = [n["index"] for n in context["flagged_notes"]]
    assert flagged_indices == [1, 2, 3, 4, 5, 6, 7]
```

Add a new test for the prompt text, right after `test_build_prompt_text_mentions_glide`:

```python
def test_build_prompt_text_mentions_pause():
    notes = [_note(0, pause_flag=True)]
    context = build_prompt_context(_score_result(notes))
    text = build_prompt_text(context)
    assert "Pause mitten in gehaltener Note: 1 Noten" in text
    assert "Pause mitten in der Note" in text
```

Add a new end-to-end-style test proving the new category matcher works, right after
`test_generate_feedback_glide_category_resolves_jump_to_t`:

```python
def test_generate_feedback_pause_category_resolves_jump_to_t(monkeypatch):
    monkeypatch.setattr("backend.feedback.generate.ANTHROPIC_API_KEY", "dummy-key")
    notes = [_note(0, pause_flag=True, sung_t=5.2)]
    score_result = _score_result(notes)
    score_result["summary"]["problem_tags"] = ["unerwartete_pause_in_gehaltener_note"]
    fake = _FakeMessagesClient(
        points=[{
            "problem": "Atempause mitten im Ton",
            "uebung_id": "unerwartete_pause_in_gehaltener_note",
        }]
    )
    result = generate_feedback(score_result, messages_client_factory=lambda: fake)
    assert result["points"][0]["jump_to_t"] == 5.2
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/test_feedback.py -v`
Expected: `test_build_prompt_text_mentions_pause` and
`test_generate_feedback_pause_category_resolves_jump_to_t` FAIL (the first because the
summary line/note text doesn't exist yet, the second because `jump_to_t` is `None`
instead of `5.2` — no matcher exists yet). The other modified tests (`_note`,
`_score_result`, `test_build_prompt_context_filters_out_unflagged_notes`) should already
PASS at this point since they only touch data shape, not behavior that depends on the
fix.

- [ ] **Step 4: Wire the matcher and prompt text**

In `backend/feedback/generate.py`, add a new matcher function after `_matches_glide`:

```python
def _matches_pause(note: dict) -> bool:
    return note["pause_flag"]
```

Replace the `_CATEGORY_MATCHERS` dict:

```python
_CATEGORY_MATCHERS: dict[str, Callable[[dict], bool]] = {
    "timingprobleme": _matches_timing,
    "absinkende_phrasenenden": _matches_drift,
    "instabile_lange_toene": _matches_stability,
    "unsaubere_einsaetze": _matches_missed,
    "haeufiges_hineingleiten": _matches_glide,
    "unerwartete_pause_in_gehaltener_note": _matches_pause,
}
```

In `backend/feedback/prompt.py`, update `build_prompt_context()`'s `is_flagged`
condition (add a new `or` clause) and the `flagged_notes.append({...})` dict:

```python
        is_flagged = (
            note["missed"]
            or note["cents_deviation"]["classification"] == "red"
            or note["timing"]["classification"] != "on_time"
            or note["stability"]["flag"]
            or note["phrase_end_drift"]["flag"]
            or note["glide"]["flag"]
            or note["pause"]["flag"]
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
                "pause_flag": note["pause"]["flag"],
                "sung_t": note["sung_t"],
            })
```

In `build_prompt_text()`, add a new summary line right after the existing
`f"- Hineingleiten in den Zielton: {summary['glide_flagged_count']} Noten",` line:

```python
        f"- Pause mitten in gehaltener Note: {summary['pause_flagged_count']} Noten",
```

And add a new `parts` entry in the per-note loop, right after the existing
`if note["glide_flag"]: parts.append(f"rutscht rein ({note['glide_direction']})")`
block:

```python
            if note["pause_flag"]:
                parts.append("Pause mitten in der Note")
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/test_feedback.py -v`
Expected: all tests PASS.

- [ ] **Step 6: Run the full backend test suite for regressions**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/ -v`
Expected: all tests PASS.

- [ ] **Step 7: Commit**

```bash
git add backend/exercises/catalog.yaml backend/feedback/generate.py backend/feedback/prompt.py tests/test_feedback.py
git commit -m "feat: add pause catalog entry, wire into feedback category matcher and prompt"
```

---

### Task 4: Mobile — ScoreNote/ScoreSummary Pause-Felder

**Files:**
- Modify: `mobile/lib/models/score_result.dart`
- Test: `mobile/test/score_result_test.dart`

**Interfaces:**
- Consumes: backend JSON shape `note["pause"] = {"applicable", "gap_seconds", "flag"}`
  and `summary["pause_flagged_count"]` from Task 2/3 (this task only needs the JSON
  shape, not runtime coupling — it supplies its own fixture in the test).
- Produces: `ScoreNote.pauseApplicable: bool`, `ScoreNote.pauseGapSeconds: double?`,
  `ScoreNote.pauseFlag: bool`; `ScoreSummary.pauseFlaggedCount: int`.

- [ ] **Step 1: Write the failing test**

In `mobile/test/score_result_test.dart`, update `_noteJson()` and `_resultJson()` to
include pause data. Replace the file's fixture functions:

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
      'pause': {'applicable': true, 'gap_seconds': 0.34, 'flag': true},
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
        'pause_flagged_count': 1,
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

(The rest of the file — the `main()`/`test(...)` block — stays unchanged; it already
round-trips whatever `_resultJson()` returns.)

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mobile && flutter test test/score_result_test.dart`
Expected: FAIL — `result.toJson()` won't include the `pause` key (since `ScoreNote`
doesn't parse or re-emit it yet), so it won't equal `original`.

- [ ] **Step 3: Add pause fields to ScoreNote and ScoreSummary**

In `mobile/lib/models/score_result.dart`:

Add three new fields to `ScoreNote`, right after `final String? glideDirection;`:

```dart
  final bool pauseApplicable;
  final double? pauseGapSeconds;
  final bool pauseFlag;
```

Add them as required constructor parameters, right after `required this.glideDirection,`:

```dart
    required this.pauseApplicable,
    required this.pauseGapSeconds,
    required this.pauseFlag,
```

In `ScoreNote.fromJson`, add parsing right after the existing
`final glide = json['glide'] as Map<String, dynamic>;` line:

```dart
    final pause = json['pause'] as Map<String, dynamic>;
```

And add the corresponding fields to the `ScoreNote(...)` constructor call, right after
`glideDirection: glide['direction'] as String?,`:

```dart
      pauseApplicable: pause['applicable'] as bool,
      pauseGapSeconds: (pause['gap_seconds'] as num?)?.toDouble(),
      pauseFlag: pause['flag'] as bool,
```

In `ScoreNote.toJson()`, add a new entry to the returned map, right after the existing
`'glide': {...},` block:

```dart
        'pause': {
          'applicable': pauseApplicable,
          'gap_seconds': pauseGapSeconds,
          'flag': pauseFlag,
        },
```

Add one new field to `ScoreSummary`, right after `final int glideFlaggedCount;`:

```dart
  final int pauseFlaggedCount;
```

Add it to the constructor, right after `required this.glideFlaggedCount,`:

```dart
    required this.pauseFlaggedCount,
```

Add it to `ScoreSummary.fromJson`, right after
`glideFlaggedCount: json['glide_flagged_count'] as int,`:

```dart
        pauseFlaggedCount: json['pause_flagged_count'] as int,
```

Add it to `ScoreSummary.toJson()`, right after `'glide_flagged_count': glideFlaggedCount,`:

```dart
        'pause_flagged_count': pauseFlaggedCount,
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mobile && flutter test test/score_result_test.dart`
Expected: PASS.

- [ ] **Step 5: Run the full mobile test suite for regressions**

Run: `cd mobile && flutter test`
Expected: all tests PASS. (Confirm no other file constructs `ScoreNote`/`ScoreSummary`
directly with positional/named args that would break on the new required fields —
`mobile/test/score_summary_view_test.dart` does construct `ScoreNote`/`ScoreSummary`
directly, and Task 5 updates that file; every other call site uses
`ScoreNote.fromJson`/`ScoreSummary.fromJson`.)

- [ ] **Step 6: Commit**

```bash
git add mobile/lib/models/score_result.dart mobile/test/score_result_test.dart
git commit -m "feat: parse and serialize pause fields in ScoreNote/ScoreSummary"
```

---

### Task 5: Mobile — Pause-Anzeige in ScoreSummaryView

**Files:**
- Modify: `mobile/lib/widgets/score_summary_view.dart`
- Modify: `mobile/test/score_summary_view_test.dart`

**Interfaces:**
- Consumes: `ScoreNote.pauseFlag`/`ScoreNote.pauseGapSeconds` from Task 4.
- Produces: no new public interface — this is the final, UI-facing task.

- [ ] **Step 1: Update the existing test fixtures to include pause fields**

`mobile/test/score_summary_view_test.dart` constructs `ScoreNote`/`ScoreSummary`
directly (not via `fromJson`), so adding required fields in Task 4 already broke this
file's compile — fix it as the first step here, before writing the new pause-specific
test.

In the `_glideNote()` helper, add pause fields right after `glideDirection: direction,`:

```dart
    pauseApplicable: false,
    pauseGapSeconds: null,
    pauseFlag: false,
```

In `_resultWith()`'s `ScoreSummary(...)`, add `pauseFlaggedCount: 0,` right after
`glideFlaggedCount: 1,`.

In `_resultWithVocalRange()`'s `ScoreSummary(...)`, add `pauseFlaggedCount: 0,` right
after `glideFlaggedCount: 0,`.

- [ ] **Step 2: Run the existing tests to verify the fixture fix compiles and passes**

Run: `cd mobile && flutter test test/score_summary_view_test.dart`
Expected: all existing tests PASS (this step only proves the fixture update is
behavior-preserving before adding new coverage).

- [ ] **Step 3: Write the new failing test**

Add a new helper function and two new tests to
`mobile/test/score_summary_view_test.dart`, after the existing `_glideNote()` function:

```dart
ScoreNote _pauseNote({required double gapSeconds}) {
  return ScoreNote(
    index: 0,
    startT: 0.0,
    endT: 3.0,
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
    glideOnsetCentsDeviation: 0.0,
    glideFlag: false,
    glideDirection: null,
    pauseApplicable: true,
    pauseGapSeconds: gapSeconds,
    pauseFlag: true,
    sungT: 0.1,
  );
}
```

Add two new `testWidgets` in `main()`, after the existing "gerutscht (von oben)" test:

```dart
  testWidgets('zeigt Pausen-Hinweis mit Luecken-Dauer fuer eine pausierte Note',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ScoreSummaryView(result: _resultWith(_pauseNote(gapSeconds: 0.34)))),
    ));
    expect(find.textContaining('Pause mitten in der Note (0.34s)'), findsOneWidget);
  });

  testWidgets('zeigt keinen Pausen-Hinweis, wenn pauseFlag false ist', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ScoreSummaryView(result: _resultWith(_glideNote(direction: 'up')))),
    ));
    expect(find.textContaining('Pause mitten in der Note'), findsNothing);
  });
```

- [ ] **Step 4: Run test to verify the new test fails**

Run: `cd mobile && flutter test test/score_summary_view_test.dart`
Expected: `zeigt Pausen-Hinweis mit Luecken-Dauer fuer eine pausierte Note` FAILS —
`find.textContaining('Pause mitten in der Note (0.34s)')` finds nothing (the widget
doesn't render pause text yet). The negative test already passes trivially (nothing
renders pause text yet regardless of the flag), which is expected and fine — Step 6
below runs the full pair together after the implementation to confirm both are
meaningful.

- [ ] **Step 5: Add pause text to ScoreSummaryView**

In `mobile/lib/widgets/score_summary_view.dart`, in `_noteLabel()`, add a new block
right after the existing `if (note.glideFlag) { ... }` block and before
`if (note.stabilityFlag) parts.add('instabil');`:

```dart
    if (note.pauseFlag) {
      parts.add('Pause mitten in der Note (${note.pauseGapSeconds!.toStringAsFixed(2)}s)');
    }
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd mobile && flutter test test/score_summary_view_test.dart`
Expected: all tests PASS, including both new pause tests.

- [ ] **Step 7: Run the full mobile test suite for regressions**

Run: `cd mobile && flutter test`
Expected: all tests PASS.

- [ ] **Step 8: Commit**

```bash
git add mobile/lib/widgets/score_summary_view.dart mobile/test/score_summary_view_test.dart
git commit -m "feat: show pause hint in ScoreSummaryView"
```

---

## Self-Review Notes

- **Spec coverage:** "Erkennung" (Task 1), "Integration in score.py" incl.
  gating/problem_tags/overall_score (Task 2), neuer Katalog-Eintrag + "Phase-6-Anschluss"
  (Task 3), "Mobile" model + display (Task 4 + 5) are all covered. Out-of-scope items
  from the spec (fehlende Atempausen an Zielstellen, Chart-Visualisierung, Aenderungen
  an `is_missed`/`classify_cents`/Timing-Logik) are untouched by every task.
- **Type consistency checked:** `compute_pause`'s return shape (Task 1,
  `{"applicable", "gap_seconds", "flag"}`) matches exactly what Task 2 stores under
  `note["pause"]` and what Task 2's `NOT_APPLICABLE_PAUSE` fallback mirrors;
  `note["pause"]["flag"]`/`note["pause"]["gap_seconds"]` (Task 2's JSON output) match
  what Task 3's `_matches_pause`/`build_prompt_context`/`build_prompt_text` read;
  `pause_flagged_count` (Task 2) matches what Task 3's `_score_result` test helper and
  `build_prompt_text` read, and what Task 4's `ScoreSummary.pauseFlaggedCount` parses
  from the same JSON key; Task 5's `pauseGapSeconds`/`pauseFlag` field names match
  exactly what Task 4 defines on `ScoreNote`.
- **No placeholders:** every step has literal code, not descriptions.

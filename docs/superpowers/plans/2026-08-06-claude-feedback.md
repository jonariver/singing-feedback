# Claude-generiertes Feedback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ein neuer Endpunkt `POST /api/feedback` liefert bis zu drei priorisierte, Claude-generierte Feedback-Punkte (Problem, Technik, Übung, optionale Wiederholungsaufgabe) zu einer bereits berechneten Bewertung; der Mobile-Client zeigt sie in einem neuen Abschnitt "5. Feedback" nach Tap auf einen Button.

**Architecture:** Neues Backend-Modul `backend/feedback/` (Katalog laden, Messwerte aus einem `ScoreResult` extrahieren, Anthropic per Tool-Use mit festem JSON-Schema aufrufen, Antwort gegen den Katalog validieren) hinter einem eigenständigen, ratenlimitierten Endpunkt. Mobile-seitig ein neues `FeedbackApi`, zentrale State-Verwaltung in `SessionState` (analog zu `score()`), und ein neues Widget für Button + Ergebniskarten.

**Tech Stack:** Python/FastAPI/Pydantic, `anthropic`-SDK (Tool-Use), `pyyaml`; Flutter/Dart, `provider`.

## Global Constraints

- `POST /api/feedback` ist ein eigener Endpunkt, nicht Teil von `/api/score`.
- Nutzt denselben `enforce_upload_rate_limit`-Mechanismus wie die anderen Endpunkte (gleiches gemeinsames Budget, kein separates Limit).
- Kein Auto-Trigger im Mobile-Client — nur auf Tap des Buttons "Feedback anfordern".
- Claudes Antwort kommt über Tool-Use mit einem JSON-Schema, dessen `uebung_id`-Feld als Enum auf die tatsächlichen Katalog-IDs beschränkt ist — kein Freitext-Parsing.
- `technik`/`uebung` im Ergebnis kommen immer aus `exercises/catalog.yaml` (kuratierter Text), nie aus Claudes Freitext.
- Fehlt `ANTHROPIC_API_KEY`, antwortet der Endpunkt mit HTTP 503 und einer deutschen Fehlermeldung statt eines rohen SDK-Fehlers.
- Leere `problem_tags` → `{"points": []}` ohne API-Aufruf.
- `ANTHROPIC_MODEL` (bereits in `backend/config.py` vorhanden, Default `"claude-sonnet-5"`) wird für den Aufruf verwendet — keine neue Modell-Konfiguration nötig.

---

### Task 1: Übungskatalog laden + Messwerte für den Prompt extrahieren

**Files:**
- Create: `backend/feedback/__init__.py`
- Create: `backend/feedback/catalog.py`
- Create: `backend/feedback/prompt.py`
- Test: `tests/test_feedback.py` (neu)

**Interfaces:**
- Produces:
  - `catalog.load_catalog(path: Path = _CATALOG_PATH) -> list[dict]`
  - `catalog.catalog_ids(catalog: list[dict]) -> list[str]`
  - `catalog.lookup(catalog: list[dict], exercise_id: str) -> dict | None`
  - `prompt.build_prompt_context(score_result: dict) -> dict` (liefert `{"summary": dict, "flagged_notes": list[dict]}`)
  - `prompt.build_prompt_text(context: dict) -> str`
- Consumes: nichts aus früheren Tasks (erster Task).

- [ ] **Step 1: `backend/feedback/__init__.py` anlegen**

```python
"""Claude-generiertes Feedback (Phase 6): siehe generate.py fuer den Orchestrator,
der von backend/api/routes.py aufgerufen wird."""
```

- [ ] **Step 2: Failing-Tests für `catalog.py` schreiben**

Erstelle `tests/test_feedback.py`:

```python
"""Tests fuer das Feedback-Modul (Phase 6)."""

from __future__ import annotations

from backend.feedback.catalog import catalog_ids, load_catalog, lookup


def test_load_catalog_returns_list_of_entries(tmp_path):
    catalog_file = tmp_path / "catalog.yaml"
    catalog_file.write_text(
        "- id: test_id\n  problem: Testproblem\n  technik: Testtechnik\n  uebung: Testuebung\n",
        encoding="utf-8",
    )
    catalog = load_catalog(catalog_file)
    assert catalog == [
        {"id": "test_id", "problem": "Testproblem", "technik": "Testtechnik", "uebung": "Testuebung"}
    ]


def test_catalog_ids_extracts_all_ids():
    catalog = [{"id": "a", "problem": "P"}, {"id": "b", "problem": "Q"}]
    assert catalog_ids(catalog) == ["a", "b"]


def test_lookup_finds_entry_by_id():
    catalog = [{"id": "a", "problem": "P"}, {"id": "b", "problem": "Q"}]
    assert lookup(catalog, "b") == {"id": "b", "problem": "Q"}


def test_lookup_returns_none_for_unknown_id():
    catalog = [{"id": "a", "problem": "P"}]
    assert lookup(catalog, "nonexistent") is None
```

- [ ] **Step 2b: Test ausführen, Fehlschlag bestätigen**

Run: `.venv/bin/python -m pytest tests/test_feedback.py -v`
Expected: FAIL — `backend.feedback.catalog` existiert nicht (Import-Fehler).

- [ ] **Step 3: `backend/feedback/catalog.py` implementieren**

```python
"""Laedt und durchsucht den kuratierten Uebungskatalog (exercises/catalog.yaml).
Der Katalog-Kommentar selbst haelt fest: Claude soll bevorzugt aus diesen
Eintraegen waehlen statt Uebungen frei zu erfinden - lookup() ist der Ort, an
dem diese Regel technisch durchgesetzt wird (siehe generate.py)."""

from __future__ import annotations

from pathlib import Path

import yaml

_CATALOG_PATH = Path(__file__).resolve().parent.parent / "exercises" / "catalog.yaml"


def load_catalog(path: Path = _CATALOG_PATH) -> list[dict]:
    """Laedt den Uebungskatalog aus der YAML-Datei. Jeder Eintrag hat mindestens
    id, problem, technik, uebung (siehe exercises/catalog.yaml)."""
    with open(path, encoding="utf-8") as f:
        return yaml.safe_load(f) or []


def catalog_ids(catalog: list[dict]) -> list[str]:
    """Liste aller IDs im Katalog, z.B. fuer ein Enum im Anthropic-Tool-Schema."""
    return [entry["id"] for entry in catalog]


def lookup(catalog: list[dict], exercise_id: str) -> dict | None:
    """Findet einen Katalog-Eintrag per ID, oder None wenn nicht vorhanden."""
    for entry in catalog:
        if entry["id"] == exercise_id:
            return entry
    return None
```

- [ ] **Step 4: Test ausführen, Erfolg bestätigen**

Run: `.venv/bin/python -m pytest tests/test_feedback.py -v`
Expected: PASS, 4 Tests grün.

- [ ] **Step 5: Failing-Tests für `prompt.py` ergänzen**

Füge am Ende von `tests/test_feedback.py` an (nach den `catalog.py`-Tests, vor der Datei-Ende — Import-Zeile am Dateianfang ergänzen):

```python
from backend.feedback.prompt import build_prompt_context, build_prompt_text
```

(diese Zeile zur bestehenden Import-Sektion oben in der Datei hinzufügen, direkt unter der `catalog`-Import-Zeile)

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
    }


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
            "overall_score": 100.0,
            "problem_tags": [],
        },
    }


def test_build_prompt_context_filters_out_unflagged_notes():
    notes = [
        _note(0),
        _note(1, missed=True),
        _note(2, cents_classification="red", cents_value=120.0),
        _note(3, timing_classification="too_late", timing_deviation_ms=250.0),
        _note(4, stability_flag=True),
        _note(5, drift_flag=True, drift_direction="down"),
    ]
    context = build_prompt_context(_score_result(notes))
    flagged_indices = [n["index"] for n in context["flagged_notes"]]
    assert flagged_indices == [1, 2, 3, 4, 5]


def test_build_prompt_context_includes_summary_unchanged():
    notes = [_note(0, missed=True)]
    score_result = _score_result(notes)
    context = build_prompt_context(score_result)
    assert context["summary"] == score_result["summary"]


def test_build_prompt_text_mentions_key_summary_numbers():
    notes = [_note(0, missed=True)]
    context = build_prompt_context(_score_result(notes))
    text = build_prompt_text(context)
    assert "Verfehlte Noten: 1" in text
    assert "Note 1:" in text
    assert "verfehlt" in text


def test_build_prompt_text_says_keine_when_no_flagged_notes():
    notes = [_note(0)]
    context = build_prompt_context(_score_result(notes))
    text = build_prompt_text(context)
    assert "- keine" in text
```

- [ ] **Step 6: Test ausführen, Fehlschlag bestätigen**

Run: `.venv/bin/python -m pytest tests/test_feedback.py -v`
Expected: die 4 neuen Tests FAIL — `backend.feedback.prompt` existiert nicht.

- [ ] **Step 7: `backend/feedback/prompt.py` implementieren**

```python
"""Extrahiert Messwerte aus einem ScoreResult (backend/scoring/score.py::score_performance())
fuer den Claude-Feedback-Prompt und baut daraus den Prompt-Text. Trennt bewusst
Messwert (harte Zahlen aus context) von der Aufgabe an Claude (siehe build_prompt_text)."""

from __future__ import annotations


def build_prompt_context(score_result: dict) -> dict:
    """Extrahiert die Summary-Zahlen plus eine kompakte Liste der auffaelligen Noten
    (verfehlt, Cent-Klassifizierung rot, oder timing-/stabilitaets-/drift-geflaggt).
    Unauffaellige Noten werden nicht mitgeschickt, um Tokens zu sparen und Claude
    nicht mit Nicht-Problemen abzulenken."""
    summary = score_result["summary"]
    flagged_notes = []
    for note in score_result["notes"]:
        is_flagged = (
            note["missed"]
            or note["cents_deviation"]["classification"] == "red"
            or note["timing"]["classification"] != "on_time"
            or note["stability"]["flag"]
            or note["phrase_end_drift"]["flag"]
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
            })
    return {"summary": summary, "flagged_notes": flagged_notes}


def build_prompt_text(context: dict) -> str:
    """Baut den Prompt-Text: trennt klar die uebergebenen Messwerte (Fakten) von der
    Aufgabe an Claude (priorisierte Punkte ableiten, keine Vermutungen ueber nicht
    gemessene Dinge)."""
    summary = context["summary"]
    flagged_notes = context["flagged_notes"]

    lines = [
        "Du bist Gesangscoach und wertest die Messwerte einer Gesangsaufnahme aus, "
        "die mit einer Zielmelodie verglichen wurde.",
        "",
        "MESSWERTE (Fakten, direkt aus der Audioanalyse - keine Interpretation):",
        f"- Anzahl bewerteter Noten: {summary['note_count']}",
        f"- Verfehlte Noten: {summary['missed_count']}",
        f"- Cent-Abweichung: {summary['cents_green']} gruen, {summary['cents_yellow']} gelb, "
        f"{summary['cents_red']} rot",
        f"- Timing-Probleme (zu frueh/spaet): {summary['timing_flagged_count']} Noten",
        f"- Instabile gehaltene Toene: {summary['stability_flagged_count']} Noten",
        f"- Absinkende Phrasenenden: {summary['phrase_end_drift_flagged_count']} Noten",
        f"- Gesamtwertung: {summary['overall_score']}/100",
        "",
        "AUFFAELLIGE EINZELNOTEN (nur die mit einem Problem, zur Orientierung):",
    ]
    if flagged_notes:
        for note in flagged_notes:
            parts = [f"Note {note['index'] + 1}:"]
            if note["missed"]:
                parts.append("verfehlt")
            if note["cents_classification"] == "red" and note["cents_value"] is not None:
                parts.append(f"Cent-Abweichung {note['cents_value']:.0f}")
            if note["timing_classification"] != "on_time":
                parts.append(f"Timing {note['timing_classification']} ({note['timing_deviation_ms']}ms)")
            if note["stability_flag"]:
                parts.append("instabil")
            if note["phrase_end_drift_flag"]:
                parts.append(f"Phrasenende sackt ab ({note['phrase_end_drift_direction']})")
            lines.append("- " + " ".join(parts))
    else:
        lines.append("- keine")
    lines += [
        "",
        "AUFGABE: Leite aus GENAU DIESEN Messwerten bis zu 3 priorisierte, konkrete "
        "Feedback-Punkte ab - das groesste Problem zuerst. Nutze fuer jeden Punkt "
        "ausschliesslich eine Uebung aus dem bereitgestellten Katalog (uebung_id). "
        "Erfinde keine Probleme oder Uebungen, die nicht durch die Messwerte oder den "
        "Katalog gedeckt sind. Formuliere 'problem' als kurzen, konkreten Satz auf "
        "Deutsch, der sich auf die Messwerte bezieht.",
    ]
    return "\n".join(lines)
```

- [ ] **Step 8: Alle Tests ausführen, Erfolg bestätigen**

Run: `.venv/bin/python -m pytest tests/test_feedback.py -v`
Expected: PASS, alle 8 Tests grün.

- [ ] **Step 9: Commit**

```bash
git add backend/feedback/__init__.py backend/feedback/catalog.py backend/feedback/prompt.py tests/test_feedback.py
git commit -m "feat: load exercise catalog and extract prompt measurements for Claude feedback"
```

---

### Task 2: Anthropic-Client (Tool-Use) + Orchestrator

**Files:**
- Create: `backend/feedback/client.py`
- Create: `backend/feedback/generate.py`
- Modify: `backend/feedback/__init__.py`
- Modify: `tests/test_feedback.py` (Tests ergänzen)

**Interfaces:**
- Consumes: `catalog.load_catalog`, `catalog.catalog_ids`, `catalog.lookup` (Task 1); `prompt.build_prompt_context`, `prompt.build_prompt_text` (Task 1); `backend.config.ANTHROPIC_API_KEY`, `backend.config.ANTHROPIC_MODEL` (bereits vorhanden).
- Produces:
  - `client.request_feedback_points(messages_client, model: str, prompt_text: str, catalog_ids: list[str]) -> list[dict]`
  - `generate.generate_feedback(score_result: dict, messages_client_factory: Callable[[], Any] | None = None) -> dict` (liefert `{"points": [{"problem": str, "technik": str, "uebung": str, "wiederholungsaufgabe": str | None}]}`)
  - `generate.FeedbackUnavailableError` (Exception-Klasse)

- [ ] **Step 1: Failing-Tests für `client.py` schreiben**

Füge am Dateianfang von `tests/test_feedback.py` folgende Imports hinzu (unter den bestehenden):

```python
from types import SimpleNamespace

import pytest

from backend.feedback.client import request_feedback_points
```

Füge am Ende der Datei an:

```python
class _FakeMessagesClient:
    def __init__(self, points=None, raise_error=None):
        self._points = points if points is not None else []
        self._raise_error = raise_error
        self.last_kwargs = None

    def create(self, **kwargs):
        self.last_kwargs = kwargs
        if self._raise_error:
            raise self._raise_error
        block = SimpleNamespace(
            type="tool_use", name="return_feedback_points", input={"points": self._points}
        )
        return SimpleNamespace(content=[block])


def test_request_feedback_points_extracts_points_from_tool_use_block():
    fake = _FakeMessagesClient(points=[{"problem": "P", "uebung_id": "a"}])
    points = request_feedback_points(fake, "claude-sonnet-5", "prompt", ["a"])
    assert points == [{"problem": "P", "uebung_id": "a"}]


def test_request_feedback_points_passes_catalog_ids_as_enum_in_tool_schema():
    fake = _FakeMessagesClient(points=[])
    request_feedback_points(fake, "claude-sonnet-5", "prompt", ["a", "b"])
    schema = fake.last_kwargs["tools"][0]["input_schema"]
    assert schema["properties"]["points"]["items"]["properties"]["uebung_id"]["enum"] == ["a", "b"]


def test_request_feedback_points_raises_when_no_tool_use_block_present():
    class _NoToolUseClient:
        def create(self, **kwargs):
            return SimpleNamespace(content=[SimpleNamespace(type="text", name=None, input=None)])

    with pytest.raises(RuntimeError):
        request_feedback_points(_NoToolUseClient(), "claude-sonnet-5", "prompt", ["a"])
```

- [ ] **Step 2: Test ausführen, Fehlschlag bestätigen**

Run: `.venv/bin/python -m pytest tests/test_feedback.py -v`
Expected: die 3 neuen Tests FAIL — `backend.feedback.client` existiert nicht.

- [ ] **Step 3: `backend/feedback/client.py` implementieren**

```python
"""Kapselt den Anthropic-API-Aufruf per Tool-Use, um strukturierte Feedback-Punkte
zu bekommen (statt fragiles Freitext-Parsing). uebung_id ist im Tool-Schema als
Enum auf die tatsaechlichen Katalog-IDs beschraenkt - Claude kann technisch keine
erfundene Uebungs-ID zurueckgeben."""

from __future__ import annotations

from typing import Any, Protocol

_TOOL_NAME = "return_feedback_points"


class AnthropicMessagesClient(Protocol):
    """Minimale Schnittstelle, die request_feedback_points von einem Anthropic-
    Messages-Client braucht - injizierbar fuer Tests (siehe test_feedback.py:
    _FakeMessagesClient). generate.py uebergibt client.messages eines echten
    anthropic.Anthropic-Clients."""

    def create(self, **kwargs: Any) -> Any: ...


def _tool_schema(catalog_ids: list[str]) -> dict:
    return {
        "name": _TOOL_NAME,
        "description": "Gibt bis zu 3 priorisierte Feedback-Punkte fuer eine Gesangsaufnahme zurueck.",
        "input_schema": {
            "type": "object",
            "properties": {
                "points": {
                    "type": "array",
                    "maxItems": 3,
                    "items": {
                        "type": "object",
                        "properties": {
                            "problem": {"type": "string"},
                            "uebung_id": {"type": "string", "enum": catalog_ids},
                            "wiederholungsaufgabe": {"type": "string"},
                        },
                        "required": ["problem", "uebung_id"],
                    },
                },
            },
            "required": ["points"],
        },
    }


def request_feedback_points(
    messages_client: AnthropicMessagesClient,
    model: str,
    prompt_text: str,
    catalog_ids: list[str],
) -> list[dict]:
    """Ruft messages_client.create() per Tool-Use auf und gibt die rohen
    {problem, uebung_id, wiederholungsaufgabe?}-Punkte zurueck. Wirft RuntimeError,
    wenn die Antwort keinen verwertbaren tool_use-Block enthaelt - generate.py
    uebernimmt die weitere Fehlerbehandlung nach aussen."""
    response = messages_client.create(
        model=model,
        max_tokens=1024,
        tools=[_tool_schema(catalog_ids)],
        tool_choice={"type": "tool", "name": _TOOL_NAME},
        messages=[{"role": "user", "content": prompt_text}],
    )
    for block in response.content:
        if getattr(block, "type", None) == "tool_use" and getattr(block, "name", None) == _TOOL_NAME:
            return block.input.get("points", [])
    raise RuntimeError("Anthropic-Antwort enthielt keinen verwertbaren tool_use-Block.")
```

- [ ] **Step 4: Test ausführen, Erfolg bestätigen**

Run: `.venv/bin/python -m pytest tests/test_feedback.py -v`
Expected: PASS, alle bisherigen 11 Tests grün.

- [ ] **Step 5: Failing-Tests für `generate.py` schreiben**

Füge zum Import-Block in `tests/test_feedback.py` hinzu:

```python
from backend.feedback.generate import FeedbackUnavailableError, generate_feedback
```

Füge am Ende der Datei an:

```python
def _score_result_with_tags(problem_tags: list[str]) -> dict:
    notes = [_note(0, missed=bool(problem_tags))] if problem_tags else []
    result = _score_result(notes)
    result["summary"]["problem_tags"] = problem_tags
    return result


def test_generate_feedback_returns_empty_points_without_api_call_when_no_problem_tags():
    calls = []

    def factory():
        calls.append(1)
        return _FakeMessagesClient(points=[])

    result = generate_feedback(_score_result_with_tags([]), messages_client_factory=factory)
    assert result == {"points": []}
    assert calls == []


def test_generate_feedback_raises_when_api_key_missing(monkeypatch):
    monkeypatch.setattr("backend.feedback.generate.ANTHROPIC_API_KEY", "")
    with pytest.raises(FeedbackUnavailableError):
        generate_feedback(
            _score_result_with_tags(["timingprobleme"]),
            messages_client_factory=lambda: _FakeMessagesClient(),
        )


def test_generate_feedback_enriches_points_with_catalog_text(monkeypatch):
    monkeypatch.setattr("backend.feedback.generate.ANTHROPIC_API_KEY", "dummy-key")
    fake = _FakeMessagesClient(points=[{"problem": "Timing daneben", "uebung_id": "timingprobleme"}])
    result = generate_feedback(
        _score_result_with_tags(["timingprobleme"]), messages_client_factory=lambda: fake
    )
    expected_entry = lookup(load_catalog(), "timingprobleme")
    assert result["points"] == [{
        "problem": "Timing daneben",
        "technik": expected_entry["technik"],
        "uebung": expected_entry["uebung"],
        "wiederholungsaufgabe": None,
    }]


def test_generate_feedback_drops_points_with_unknown_uebung_id(monkeypatch):
    monkeypatch.setattr("backend.feedback.generate.ANTHROPIC_API_KEY", "dummy-key")
    fake = _FakeMessagesClient(points=[{"problem": "X", "uebung_id": "nicht_im_katalog"}])
    result = generate_feedback(
        _score_result_with_tags(["timingprobleme"]), messages_client_factory=lambda: fake
    )
    assert result["points"] == []


def test_generate_feedback_raises_when_anthropic_call_fails(monkeypatch):
    monkeypatch.setattr("backend.feedback.generate.ANTHROPIC_API_KEY", "dummy-key")
    fake = _FakeMessagesClient(raise_error=RuntimeError("boom"))
    with pytest.raises(FeedbackUnavailableError):
        generate_feedback(
            _score_result_with_tags(["timingprobleme"]), messages_client_factory=lambda: fake
        )
```

- [ ] **Step 6: Test ausführen, Fehlschlag bestätigen**

Run: `.venv/bin/python -m pytest tests/test_feedback.py -v`
Expected: die 5 neuen Tests FAIL — `backend.feedback.generate` existiert nicht.

- [ ] **Step 7: `backend/feedback/generate.py` implementieren**

```python
"""Orchestriert die Claude-Feedback-Generierung (Analogie zu scoring/score.py):
Katalog laden, Messwerte aus einem ScoreResult extrahieren, Anthropic per Tool-Use
aufrufen, Antwort gegen den Katalog validieren/anreichern."""

from __future__ import annotations

from typing import Any, Callable

import anthropic

from backend.config import ANTHROPIC_API_KEY, ANTHROPIC_MODEL
from backend.feedback.catalog import catalog_ids, load_catalog, lookup
from backend.feedback.client import request_feedback_points
from backend.feedback.prompt import build_prompt_context, build_prompt_text


class FeedbackUnavailableError(Exception):
    """API-Key fehlt oder der Anthropic-Aufruf ist fehlgeschlagen."""


def generate_feedback(
    score_result: dict,
    messages_client_factory: Callable[[], Any] | None = None,
) -> dict:
    """Liefert {"points": [...]} mit bis zu 3 Punkten (problem, technik, uebung,
    wiederholungsaufgabe). Leere Liste, wenn score_result["summary"]["problem_tags"]
    leer ist (kein API-Aufruf noetig). Wirft FeedbackUnavailableError, wenn der
    API-Key fehlt oder der Anthropic-Aufruf fehlschlaegt. messages_client_factory
    ist injizierbar fuer Tests (siehe test_feedback.py) - Default baut einen echten
    anthropic.Anthropic-Client."""
    if not score_result["summary"]["problem_tags"]:
        return {"points": []}

    if not ANTHROPIC_API_KEY:
        raise FeedbackUnavailableError("ANTHROPIC_API_KEY ist nicht konfiguriert.")

    if messages_client_factory is None:
        messages_client_factory = lambda: anthropic.Anthropic(api_key=ANTHROPIC_API_KEY).messages

    catalog = load_catalog()
    context = build_prompt_context(score_result)
    prompt_text = build_prompt_text(context)

    try:
        raw_points = request_feedback_points(
            messages_client_factory(), ANTHROPIC_MODEL, prompt_text, catalog_ids(catalog)
        )
    except Exception as exc:
        raise FeedbackUnavailableError(f"Anthropic-Aufruf fehlgeschlagen: {exc}") from exc

    points = []
    for raw in raw_points[:3]:
        entry = lookup(catalog, raw.get("uebung_id", ""))
        if entry is None:
            continue
        points.append({
            "problem": raw.get("problem") or entry["problem"],
            "technik": entry["technik"],
            "uebung": entry["uebung"],
            "wiederholungsaufgabe": raw.get("wiederholungsaufgabe"),
        })
    return {"points": points}
```

- [ ] **Step 8: `backend/feedback/__init__.py` um Exports erweitern**

Ersetze den Inhalt von `backend/feedback/__init__.py` durch:

```python
"""Claude-generiertes Feedback (Phase 6): siehe generate.py fuer den Orchestrator."""

from .generate import FeedbackUnavailableError, generate_feedback

__all__ = ["FeedbackUnavailableError", "generate_feedback"]
```

- [ ] **Step 9: Alle Tests ausführen, Erfolg bestätigen**

Run: `.venv/bin/python -m pytest tests/test_feedback.py -v`
Expected: PASS, alle 16 Tests grün.

- [ ] **Step 10: Commit**

```bash
git add backend/feedback/client.py backend/feedback/generate.py backend/feedback/__init__.py tests/test_feedback.py
git commit -m "feat: call Anthropic via tool-use and validate feedback points against the exercise catalog"
```

---

### Task 3: Endpunkt `POST /api/feedback`

**Files:**
- Modify: `backend/api/routes.py`

**Interfaces:**
- Consumes: `backend.feedback.generate_feedback`, `backend.feedback.FeedbackUnavailableError` (Task 2); `backend.api.rate_limit.enforce_upload_rate_limit`, `backend.config.MAX_SCORE_REQUEST_BYTES` (bereits vorhanden).
- Produces: `POST /api/feedback` — Request `{"score": <ScoreResult-dict>}`, Response `{"feedback": {"points": [...]}}`.

Kein neuer automatisierter Test in diesem Task: dieses Projekt hat aktuell keine
`TestClient`-basierten HTTP-Route-Tests (auch `/api/score` selbst ist nur indirekt
ueber `score_performance()` getestet, siehe `tests/test_scoring.py` /
`tests/test_e2e_phase4.py`) - `generate_feedback()` ist in Task 2 bereits
gruendlich getestet, der Route-Handler bleibt bewusst ein duenner Wrapper darum.
Verifikation hier erfolgt manuell (Step 4).

- [ ] **Step 1: Import ergänzen**

In `backend/api/routes.py`, ergänze im Import-Block (nach der bestehenden
`from backend.scoring import score_performance`-Zeile):

```python
from backend.feedback import FeedbackUnavailableError, generate_feedback
```

- [ ] **Step 2: `FeedbackRequest`-Model und Route ergänzen**

Füge in `backend/api/routes.py` nach der bestehenden `/score`-Route (nach der
`return {"score": result}`-Zeile) an:

```python
class FeedbackRequest(BaseModel):
    score: dict  # ScoreResult, wie von /api/score unter "score" zurueckgegeben


@router.post("/feedback", dependencies=[Depends(enforce_upload_rate_limit)])
def feedback(request: Request, body: FeedbackRequest) -> dict:
    _reject_oversized_content_length(request, MAX_SCORE_REQUEST_BYTES)
    try:
        result = generate_feedback(body.score)
    except FeedbackUnavailableError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except (KeyError, TypeError) as exc:
        raise HTTPException(
            status_code=400,
            detail="score-Daten sind unvollständig oder ungültig.",
        ) from exc
    return {"feedback": result}
```

- [ ] **Step 3: Bestehende Test-Suite ausführen**

Run: `.venv/bin/python -m pytest tests/ -v`
Expected: PASS, keine Regression (alle bisherigen Tests weiterhin grün, `routes.py`
importiert jetzt zusätzlich `backend.feedback` ohne Fehler).

- [ ] **Step 4: Manuelle Verifikation gegen einen laufenden Server**

In diesem Dev-Environment ist `ANTHROPIC_API_KEY` nicht gesetzt (leerer Default) -
das macht den 503-Pfad direkt real testbar, ohne echte API-Kosten zu verursachen.

Terminal 1 (Server starten):
```bash
.venv/bin/python -m uvicorn backend.main:app --port 8000
```

Terminal 2 (leere `problem_tags` → leere Punkteliste, kein API-Aufruf, kein 503):
```bash
curl -s -X POST http://127.0.0.1:8000/api/feedback \
  -H "Content-Type: application/json" \
  -d '{"score": {"notes": [], "summary": {"note_count": 0, "missed_count": 0, "cents_green": 0, "cents_yellow": 0, "cents_red": 0, "timing_flagged_count": 0, "stability_flagged_count": 0, "phrase_end_drift_flagged_count": 0, "overall_score": 100.0, "problem_tags": []}}}'
```
Expected: `{"feedback":{"points":[]}}`

Terminal 2 (nicht-leere `problem_tags`, aber ohne `ANTHROPIC_API_KEY` → 503):
```bash
curl -s -o /dev/null -w "%{http_code}\n" -X POST http://127.0.0.1:8000/api/feedback \
  -H "Content-Type: application/json" \
  -d '{"score": {"notes": [], "summary": {"note_count": 1, "missed_count": 1, "cents_green": 0, "cents_yellow": 0, "cents_red": 0, "timing_flagged_count": 0, "stability_flagged_count": 0, "phrase_end_drift_flagged_count": 0, "overall_score": 0.0, "problem_tags": ["unsaubere_einsaetze"]}}}'
```
Expected: `503`

Server danach stoppen (Ctrl+C in Terminal 1).

- [ ] **Step 5: Commit**

```bash
git add backend/api/routes.py
git commit -m "feat: add POST /api/feedback endpoint"
```

---

### Task 4: Mobile-Modelle, API-Client, SessionState-Anbindung

**Files:**
- Create: `mobile/lib/models/feedback_result.dart`
- Create: `mobile/lib/api/feedback_api.dart`
- Create: `mobile/test/score_result_test.dart`
- Modify: `mobile/lib/models/score_result.dart` (toJson()-Methoden ergänzen)
- Modify: `mobile/lib/state/session_state.dart`
- Modify: `mobile/lib/main.dart`
- Modify: `mobile/test/session_state_test.dart`

**Interfaces:**
- Consumes: `POST /api/feedback`-Response-Form aus Task 3 (`{"feedback": {"points": [{"problem", "technik", "uebung", "wiederholungsaufgabe"}]}}`).
- Produces:
  - `FeedbackPoint` (`problem: String`, `technik: String`, `uebung: String`, `wiederholungsaufgabe: String?`), `FeedbackPoint.fromJson`
  - `FeedbackResult` (`points: List<FeedbackPoint>`), `FeedbackResult.fromJson`
  - `FeedbackApi.requestFeedback(Map<String, dynamic> scoreJson) -> Future<FeedbackResult>`
  - `ScoreNote.toJson()`, `ScoreSummary.toJson()`, `ScoreResult.toJson()`
  - `SessionState.feedbackApi` (Feld), `SessionState.feedbackResult` (`FeedbackResult?`), `SessionState.feedbackStatus` (`LoadStatus`), `SessionState.feedbackMessage` (`String`), `SessionState.requestFeedback() -> Future<void>`

- [ ] **Step 1: `mobile/lib/models/feedback_result.dart` anlegen**

```dart
/// Ergebnis von POST /api/feedback (backend/api/routes.py::feedback), siehe
/// docs/superpowers/specs/2026-08-06-claude-feedback-design.md.
class FeedbackPoint {
  final String problem;
  final String technik;
  final String uebung;
  final String? wiederholungsaufgabe;

  const FeedbackPoint({
    required this.problem,
    required this.technik,
    required this.uebung,
    required this.wiederholungsaufgabe,
  });

  factory FeedbackPoint.fromJson(Map<String, dynamic> json) => FeedbackPoint(
        problem: json['problem'] as String,
        technik: json['technik'] as String,
        uebung: json['uebung'] as String,
        wiederholungsaufgabe: json['wiederholungsaufgabe'] as String?,
      );
}

class FeedbackResult {
  final List<FeedbackPoint> points;

  const FeedbackResult({required this.points});

  factory FeedbackResult.fromJson(Map<String, dynamic> json) => FeedbackResult(
        points: (json['points'] as List)
            .cast<Map<String, dynamic>>()
            .map(FeedbackPoint.fromJson)
            .toList(),
      );
}
```

- [ ] **Step 2: `mobile/lib/api/feedback_api.dart` anlegen**

```dart
import '../models/feedback_result.dart';
import 'api_client.dart';

/// Ruft POST /api/feedback auf (backend/api/routes.py::feedback) und liefert das
/// geparste Claude-Feedback. Nimmt das bereits vom Server erhaltene ScoreResult-JSON
/// entgegen (via ScoreResult.toJson()) - keine Neuberechnung noetig.
class FeedbackApi {
  final ApiClient _client;

  FeedbackApi(this._client);

  Future<FeedbackResult> requestFeedback(Map<String, dynamic> scoreJson) async {
    final json = await _client.postJson('/api/feedback', {'score': scoreJson});
    return FeedbackResult.fromJson(json['feedback'] as Map<String, dynamic>);
  }
}
```

- [ ] **Step 3: Failing-Test für `ScoreResult.toJson()` schreiben**

Erstelle `mobile/test/score_result_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:singing_feedback_mobile/models/score_result.dart';

Map<String, dynamic> _noteJson() => {
      'index': 0, 'start_t': 0.0, 'end_t': 1.0,
      'target_hz': 440.0, 'target_midi_note': 69,
      'missed': false, 'coverage_fraction': 1.0,
      'cents_deviation': {'value': 1.2, 'classification': 'green'},
      'timing': {'deviation_ms': 4.0, 'classification': 'on_time'},
      'held': true,
      'stability': {'applicable': true, 'mad_cents': 0.8, 'flag': false},
      'phrase_end_drift': {'applicable': true, 'drift_cents': 0.3, 'flag': false, 'direction': null},
    };

Map<String, dynamic> _resultJson() => {
      'notes': [_noteJson()],
      'summary': {
        'note_count': 1, 'missed_count': 0,
        'cents_green': 1, 'cents_yellow': 0, 'cents_red': 0,
        'timing_flagged_count': 0, 'stability_flagged_count': 0,
        'phrase_end_drift_flagged_count': 0,
        'overall_score': 100.0,
        'problem_tags': <String>[],
      },
    };

void main() {
  test('ScoreResult.toJson() ist die Umkehrung von ScoreResult.fromJson()', () {
    final original = _resultJson();
    final result = ScoreResult.fromJson(original);
    expect(result.toJson(), original);
  });
}
```

- [ ] **Step 4: Test ausführen, Fehlschlag bestätigen**

Run: `cd mobile && flutter test test/score_result_test.dart`
Expected: FAIL — `toJson` ist auf `ScoreResult` nicht definiert (Compile-Fehler).

- [ ] **Step 5: `toJson()` in `mobile/lib/models/score_result.dart` ergänzen**

Füge in der `ScoreNote`-Klasse (nach dem bestehenden `factory ScoreNote.fromJson(...)`-Block, vor der schließenden `}` der Klasse) an:

```dart
  Map<String, dynamic> toJson() => {
        'index': index,
        'start_t': startT,
        'end_t': endT,
        'target_hz': targetHz,
        'target_midi_note': targetMidiNote,
        'missed': missed,
        'coverage_fraction': coverageFraction,
        'cents_deviation': {'value': centsValue, 'classification': centsClassification},
        'timing': {'deviation_ms': timingDeviationMs, 'classification': timingClassification},
        'held': held,
        'stability': {
          'applicable': stabilityApplicable,
          'mad_cents': stabilityMadCents,
          'flag': stabilityFlag,
        },
        'phrase_end_drift': {
          'applicable': driftApplicable,
          'drift_cents': driftCents,
          'flag': phraseEndDriftFlag,
          'direction': driftDirection,
        },
      };
```

Füge in der `ScoreSummary`-Klasse (nach dem bestehenden `factory ScoreSummary.fromJson(...)`-Block, vor der schließenden `}` der Klasse) an:

```dart
  Map<String, dynamic> toJson() => {
        'note_count': noteCount,
        'missed_count': missedCount,
        'cents_green': centsGreen,
        'cents_yellow': centsYellow,
        'cents_red': centsRed,
        'timing_flagged_count': timingFlaggedCount,
        'stability_flagged_count': stabilityFlaggedCount,
        'phrase_end_drift_flagged_count': phraseEndDriftFlaggedCount,
        'overall_score': overallScore,
        'problem_tags': problemTags,
      };
```

Füge in der `ScoreResult`-Klasse (nach dem bestehenden `factory ScoreResult.fromJson(...)`-Block, vor der schließenden `}` der Klasse) an:

```dart
  Map<String, dynamic> toJson() => {
        'notes': notes.map((n) => n.toJson()).toList(),
        'summary': summary.toJson(),
      };
```

- [ ] **Step 6: Test ausführen, Erfolg bestätigen**

Run: `cd mobile && flutter test test/score_result_test.dart`
Expected: PASS.

- [ ] **Step 7: `SessionState` um Feedback-State und `requestFeedback()` erweitern**

In `mobile/lib/state/session_state.dart`:

Ergänze den Import-Block (nach `import '../api/score_api.dart';`):

```dart
import '../api/feedback_api.dart';
import '../models/feedback_result.dart';
```

Ändere den Konstruktor und das `scoreApi`-Feld (Zeilen 22-32 im aktuellen Stand):

```dart
  final MidiApi midiApi;
  final AudioApi audioApi;
  final SyncApi syncApi;
  final ScoreApi scoreApi;
  final FeedbackApi feedbackApi;

  SessionState({
    required this.midiApi,
    required this.audioApi,
    required this.syncApi,
    required this.scoreApi,
    required this.feedbackApi,
  });
```

Ergänze nach den bestehenden `scoreResult`/`scoreStatus`/`scoreMessage`-Feldern (nach Zeile 61 im aktuellen Stand):

```dart
  FeedbackResult? feedbackResult;
  LoadStatus feedbackStatus = LoadStatus.idle;
  String feedbackMessage = '';
```

Ergänze im bestehenden `score()`-Methodenkörper direkt nach der
`if (alignedSungCurve.isEmpty) return;`-Zeile (bevor `scoreStatus = LoadStatus.loading;`)
folgende drei Zeilen, damit ein veraltetes Feedback nie an einer neu berechneten
Bewertung haengen bleibt (z.B. nach einer Transpose-Aenderung, die score() direkt
erneut ausloest, ohne ueber _resetAlignment() zu gehen):

```dart
    feedbackResult = null;
    feedbackStatus = LoadStatus.idle;
    feedbackMessage = '';
```

Ergänze in `_resetAlignment()` (nach den bestehenden `scoreResult = null;` /
`scoreStatus = LoadStatus.idle;` / `scoreMessage = '';`-Zeilen) dieselben drei
Zeilen:

```dart
    feedbackResult = null;
    feedbackStatus = LoadStatus.idle;
    feedbackMessage = '';
```

Ergänze eine neue Methode direkt nach `score()`:

```dart
  /// Fordert Claude-generiertes Feedback zur aktuellen Bewertung an (POST
  /// /api/feedback). Nur auf Nutzer-Wunsch (Button in HomeScreen), kein
  /// Auto-Trigger wie bei align()/score() - jeder Aufruf loest eine echte,
  /// kostenpflichtige Anthropic-API-Anfrage aus.
  Future<void> requestFeedback() async {
    if (scoreResult == null) return;
    feedbackStatus = LoadStatus.loading;
    feedbackMessage = 'Hole Feedback…';
    notifyListeners();
    try {
      feedbackResult = await feedbackApi.requestFeedback(scoreResult!.toJson());
      feedbackStatus = LoadStatus.ok;
      feedbackMessage = 'Feedback fertig.';
    } catch (e) {
      feedbackStatus = LoadStatus.error;
      feedbackMessage = 'Feedback fehlgeschlagen: ${_messageOf(e)}';
    }
    notifyListeners();
  }
```

- [ ] **Step 8: `mobile/lib/main.dart` anpassen**

In `mobile/lib/main.dart`, ergänze den Import (nach dem bestehenden `ScoreApi`-Import):

```dart
import 'api/feedback_api.dart';
```

Ergänze im `SessionState(...)`-Konstruktoraufruf (nach `scoreApi: ScoreApi(apiClient),`):

```dart
        feedbackApi: FeedbackApi(apiClient),
```

- [ ] **Step 9: `mobile/test/session_state_test.dart` anpassen**

Ergänze den Import-Block (nach `import 'package:singing_feedback_mobile/api/score_api.dart';`):

```dart
import 'package:singing_feedback_mobile/api/feedback_api.dart';
```

Erweitere `_FakeApiClient.postJson` (bestehende Methode), damit sie nach `path`
unterscheidet statt immer die Score-Antwort zu liefern — ersetze die bestehende
Methode durch:

```dart
  Object? throwOnFeedback;
  Map<String, dynamic> feedbackResponse = {
    'feedback': {
      'points': [
        {
          'problem': 'Timing daneben',
          'technik': 'Testtechnik',
          'uebung': 'Testuebung',
          'wiederholungsaufgabe': null,
        },
      ],
    },
  };

  @override
  Future<Map<String, dynamic>> postJson(String path, Map<String, dynamic> body) async {
    lastPostJsonBody = body;
    if (path == '/api/feedback') {
      if (throwOnFeedback != null) throw throwOnFeedback!;
      return feedbackResponse;
    }
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
```

(`throwOnFeedback` und `feedbackResponse` sind neue Felder auf `_FakeApiClient`,
direkt über der `postJson`-Methode deklariert; `lastPostJsonBody` bleibt wie
bisher als separates Feld erhalten.)

Ändere `_buildSession()` (fügt `feedbackApi` hinzu):

```dart
SessionState _buildSession() {
  final client = _FakeApiClient();
  return SessionState(
    midiApi: MidiApi(client),
    audioApi: AudioApi(client),
    syncApi: SyncApi(client),
    scoreApi: ScoreApi(client),
    feedbackApi: FeedbackApi(client),
  );
}
```

Ändere die zweite, eigenständige `SessionState(...)`-Konstruktion (im Test
`'score() sendet im Referenz-Modus die TRANSPONIERTE Anzeigekurve...'`, aktuell
ohne `feedbackApi`) genauso:

```dart
    final session = SessionState(
      midiApi: MidiApi(client),
      audioApi: AudioApi(client),
      syncApi: SyncApi(client),
      scoreApi: ScoreApi(client),
      feedbackApi: FeedbackApi(client),
    );
```

Füge am Ende der Datei (vor der letzten schließenden `}` von `main()`) neue Tests
für `requestFeedback()` an:

```dart
  test('requestFeedback() setzt feedbackResult nach erfolgreichem Aufruf', () async {
    final session = _buildSession();
    await session.analyzeAudio(Uint8List.fromList([1, 2, 3]), 'gesang.wav');
    await session.score();

    await session.requestFeedback();

    expect(session.feedbackStatus, LoadStatus.ok);
    expect(session.feedbackResult, isNotNull);
    expect(session.feedbackResult!.points.first.problem, 'Timing daneben');
  });

  test('requestFeedback() setzt feedbackStatus auf error, wenn der Aufruf fehlschlaegt', () async {
    final client = _FakeApiClient()..throwOnFeedback = ApiException(503, 'Feedback nicht verfuegbar.');
    final session = SessionState(
      midiApi: MidiApi(client),
      audioApi: AudioApi(client),
      syncApi: SyncApi(client),
      scoreApi: ScoreApi(client),
      feedbackApi: FeedbackApi(client),
    );
    await session.analyzeAudio(Uint8List.fromList([1, 2, 3]), 'gesang.wav');
    await session.score();

    await session.requestFeedback();

    expect(session.feedbackStatus, LoadStatus.error);
    expect(session.feedbackMessage, contains('Feedback nicht verfuegbar'));
  });

  test('requestFeedback() ohne scoreResult tut nichts', () async {
    final session = _buildSession();
    await session.requestFeedback();
    expect(session.feedbackStatus, LoadStatus.idle);
  });

  test('ein erneutes score() setzt ein zuvor geholtes feedbackResult zurueck', () async {
    final session = _buildSession();
    await session.analyzeAudio(Uint8List.fromList([1, 2, 3]), 'gesang.wav');
    await session.score();
    await session.requestFeedback();
    expect(session.feedbackResult, isNotNull);

    await session.score();

    expect(session.feedbackResult, isNull);
    expect(session.feedbackStatus, LoadStatus.idle);
  });
```

`analyzeAudio()` ruft intern bereits `await align();` auf, bevor es zurueckkehrt
(siehe `session_state.dart::analyzeAudio`) - `alignedSungCurve` ist also nach
`await session.analyzeAudio(...)` bereits befuellt, ein zusaetzlicher expliziter
`align()`-Aufruf in den neuen Tests ist nicht noetig.

- [ ] **Step 10: Backend- und Mobile-Tests ausführen**

Run: `cd mobile && flutter test -j 1`
Expected: PASS, keine Regression, alle bestehenden plus die neuen Tests grün.

- [ ] **Step 11: `flutter analyze` ausführen**

Run: `cd mobile && flutter analyze`
Expected: keine Fehler/Warnungen.

- [ ] **Step 12: Commit**

```bash
git add mobile/lib/models/feedback_result.dart mobile/lib/api/feedback_api.dart mobile/test/score_result_test.dart mobile/lib/models/score_result.dart mobile/lib/state/session_state.dart mobile/lib/main.dart mobile/test/session_state_test.dart
git commit -m "feat: add FeedbackApi, ScoreResult.toJson(), and SessionState.requestFeedback()"
```

---

### Task 5: Feedback-Widget + HomeScreen-Wiring

**Files:**
- Create: `mobile/lib/widgets/feedback_section.dart`
- Create: `mobile/test/feedback_section_test.dart`
- Modify: `mobile/lib/screens/home_screen.dart`

**Interfaces:**
- Consumes: `SessionState.scoreResult`, `SessionState.feedbackResult`, `SessionState.feedbackStatus`, `SessionState.feedbackMessage`, `SessionState.requestFeedback()` (Task 4); `FeedbackPoint`, `FeedbackResult` (Task 4).
- Produces: `FeedbackSection` Widget (`{required SessionState session}`).

- [ ] **Step 1: Failing-Test für `FeedbackSection` schreiben**

Erstelle `mobile/test/feedback_section_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:singing_feedback_mobile/api/api_client.dart';
import 'package:singing_feedback_mobile/api/audio_api.dart';
import 'package:singing_feedback_mobile/api/feedback_api.dart';
import 'package:singing_feedback_mobile/api/midi_api.dart';
import 'package:singing_feedback_mobile/api/score_api.dart';
import 'package:singing_feedback_mobile/api/sync_api.dart';
import 'package:singing_feedback_mobile/models/score_result.dart';
import 'package:singing_feedback_mobile/state/session_state.dart';
import 'package:singing_feedback_mobile/widgets/feedback_section.dart';

class _FakeApiClient extends ApiClient {
  _FakeApiClient() : super(baseUrl: 'http://fake.local');

  Object? throwOnFeedback;
  Map<String, dynamic> feedbackResponse = {
    'feedback': {
      'points': [
        {
          'problem': 'Timing daneben',
          'technik': 'Testtechnik',
          'uebung': 'Testuebung',
          'wiederholungsaufgabe': null,
        },
      ],
    },
  };

  @override
  Future<Map<String, dynamic>> postJson(String path, Map<String, dynamic> body) async {
    if (throwOnFeedback != null) throw throwOnFeedback!;
    return feedbackResponse;
  }
}

ScoreResult _dummyScoreResult({List<String> problemTags = const ['timingprobleme']}) {
  return ScoreResult(
    notes: const [],
    summary: ScoreSummary(
      noteCount: 1,
      missedCount: 0,
      centsGreen: 1,
      centsYellow: 0,
      centsRed: 0,
      timingFlaggedCount: 1,
      stabilityFlaggedCount: 0,
      phraseEndDriftFlaggedCount: 0,
      overallScore: 85.0,
      problemTags: problemTags,
    ),
  );
}

SessionState _buildSession(_FakeApiClient client) {
  return SessionState(
    midiApi: MidiApi(client),
    audioApi: AudioApi(client),
    syncApi: SyncApi(client),
    scoreApi: ScoreApi(client),
    feedbackApi: FeedbackApi(client),
  );
}

Widget _wrap(SessionState session) {
  return ChangeNotifierProvider<SessionState>.value(
    value: session,
    child: MaterialApp(
      home: Scaffold(
        body: Consumer<SessionState>(
          builder: (context, session, _) => FeedbackSection(session: session),
        ),
      ),
    ),
  );
}

void main() {
  group('FeedbackSection', () {
    testWidgets('rendert nichts ohne scoreResult', (tester) async {
      final session = _buildSession(_FakeApiClient());
      await tester.pumpWidget(_wrap(session));
      expect(find.text('Feedback anfordern'), findsNothing);
    });

    testWidgets('Tap auf den Button zeigt nach Erfolg eine Feedback-Karte', (tester) async {
      final session = _buildSession(_FakeApiClient())..scoreResult = _dummyScoreResult();
      await tester.pumpWidget(_wrap(session));

      expect(find.text('Feedback anfordern'), findsOneWidget);
      await tester.tap(find.text('Feedback anfordern'));
      await tester.pumpAndSettle();

      expect(find.text('Timing daneben'), findsOneWidget);
      expect(find.text('Testtechnik'), findsOneWidget);
      expect(find.text('Testuebung'), findsOneWidget);
    });

    testWidgets('zeigt eine Fehlermeldung, wenn die Feedback-Anfrage fehlschlaegt', (tester) async {
      final client = _FakeApiClient()
        ..throwOnFeedback = ApiException(503, 'Feedback nicht verfuegbar.');
      final session = _buildSession(client)..scoreResult = _dummyScoreResult();
      await tester.pumpWidget(_wrap(session));

      await tester.tap(find.text('Feedback anfordern'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Feedback fehlgeschlagen'), findsOneWidget);
    });

    testWidgets('zeigt eine Hinweis-Meldung, wenn keine Punkte zurueckkommen', (tester) async {
      final client = _FakeApiClient()..feedbackResponse = {'feedback': {'points': <dynamic>[]}};
      final session = _buildSession(client)..scoreResult = _dummyScoreResult();
      await tester.pumpWidget(_wrap(session));

      await tester.tap(find.text('Feedback anfordern'));
      await tester.pumpAndSettle();

      expect(find.text('Keine besonderen Probleme erkannt.'), findsOneWidget);
    });
  });
}
```

- [ ] **Step 2: Test ausführen, Fehlschlag bestätigen**

Run: `cd mobile && flutter test test/feedback_section_test.dart`
Expected: FAIL — `feedback_section.dart` existiert nicht.

- [ ] **Step 3: `mobile/lib/widgets/feedback_section.dart` implementieren**

```dart
import 'package:flutter/material.dart';

import '../models/feedback_result.dart';
import '../state/session_state.dart';

/// Abschnitt "5. Feedback": Button "Feedback anfordern" (kein Auto-Trigger, jeder
/// Aufruf loest eine echte, kostenpflichtige Anthropic-API-Anfrage aus) plus bis
/// zu drei Feedback-Karten nach erfolgreichem Aufruf. Rendert nichts, solange
/// keine Bewertung vorliegt. Anders als PlaybackButton/ShareButton kein eigener
/// injizierbarer Controller noetig: der HTTP-Aufruf laeuft zentral ueber
/// SessionState.requestFeedback() (wie score()/align()), Ladezustand/Fehler
/// kommen aus session.feedbackStatus/feedbackMessage.
class FeedbackSection extends StatelessWidget {
  final SessionState session;

  const FeedbackSection({super.key, required this.session});

  @override
  Widget build(BuildContext context) {
    if (session.scoreResult == null) return const SizedBox.shrink();
    final isLoading = session.feedbackStatus == LoadStatus.loading;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ElevatedButton(
          onPressed: isLoading ? null : session.requestFeedback,
          child: Text(isLoading ? 'Hole Feedback…' : 'Feedback anfordern'),
        ),
        if (session.feedbackStatus == LoadStatus.error)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              session.feedbackMessage,
              style: TextStyle(color: Colors.red.shade300, fontSize: 12),
            ),
          ),
        if (session.feedbackResult != null && session.feedbackResult!.points.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('Keine besonderen Probleme erkannt.'),
          ),
        if (session.feedbackResult != null)
          for (final point in session.feedbackResult!.points) _FeedbackPointCard(point: point),
      ],
    );
  }
}

class _FeedbackPointCard extends StatelessWidget {
  final FeedbackPoint point;

  const _FeedbackPointCard({required this.point});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(point.problem, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(point.technik),
            const SizedBox(height: 4),
            Text(point.uebung),
            if (point.wiederholungsaufgabe != null) ...[
              const SizedBox(height: 4),
              Text('Wiederholung: ${point.wiederholungsaufgabe}'),
            ],
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Test ausführen, Erfolg bestätigen**

Run: `cd mobile && flutter test test/feedback_section_test.dart`
Expected: PASS, alle 4 Tests grün.

- [ ] **Step 5: In `home_screen.dart` verdrahten**

Ergänze den Import (nach `import '../widgets/score_summary_view.dart';`):

```dart
import '../widgets/feedback_section.dart';
```

Ergänze am Ende des `Column`-`children`-Blocks, direkt nach der bestehenden Zeile
`if (session.scoreResult != null) ScoreSummaryView(result: session.scoreResult!),`
(letzter Eintrag vor der schließenden `],` der `children`-Liste):

```dart
            const Divider(height: 32),
            Text('5. Feedback', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            FeedbackSection(session: session),
```

- [ ] **Step 6: Vollen Test-Suite-Lauf und Analyse verifizieren**

Run: `cd mobile && flutter test -j 1`
Expected: alle Tests grün.

Run: `cd mobile && flutter analyze`
Expected: keine Fehler/Warnungen.

- [ ] **Step 7: Commit**

```bash
git add mobile/lib/widgets/feedback_section.dart mobile/test/feedback_section_test.dart mobile/lib/screens/home_screen.dart
git commit -m "feat: add Feedback section with request button and result cards to HomeScreen"
```

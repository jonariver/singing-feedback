# Cloudflare Workers AI als wählbarer Feedback-Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Cloudflare Workers AI (`@cf/qwen/qwen3-30b-a3b-fp8`) as a second,
in-app-selectable provider for the Phase 6 feedback-generation feature, alongside
the existing Anthropic integration.

**Architecture:** A new `backend/feedback/cloudflare_client.py` module makes a raw
REST call to Workers AI via `httpx`, using an OpenAI-style function-calling tool
schema, and reuses the existing `client.py::_normalize_points()` shape-defense
helper (the same live-observed Claude schema-adherence quirks are, if anything,
more likely with a much smaller model). `generate.py`'s orchestrator gains a
`provider` parameter that dispatches between the two client modules while the rest
of the function (catalog enrichment, `jump_to_t` resolution, response shape) stays
provider-agnostic. Mobile mirrors the existing `TolerancePreset`/
`TolerancePresetControl` pattern exactly, with one deliberate difference: no
auto-retriggered request on provider change, since feedback calls are paid and
manual-only.

**Tech Stack:** Python (backend/feedback, backend/config.py, backend/api/routes.py),
`httpx` (new explicit dependency), Dart/Flutter (mobile/lib/models,
mobile/lib/state, mobile/lib/widgets, mobile/lib/api), pytest, flutter_test.

## Global Constraints

- Cloudflare model is fixed: `@cf/qwen/qwen3-30b-a3b-fp8`. No model-selection UI —
  out of scope per the approved spec.
- No new Python dependency beyond `httpx`, which is already installed transitively
  (via `anthropic`) but must be added explicitly to `requirements.txt` — do not add
  `openai` or any other SDK.
- `request_feedback_points()` in both `client.py` (Anthropic) and
  `cloudflare_client.py` (Cloudflare) must return the exact same shape:
  `list[dict]` of `{"problem": str, "uebung_id": str, "wiederholungsaufgabe": str?}`
  entries — `generate.py`'s downstream code must not need to know which provider
  produced the list.
- `cloudflare_client.py` MUST reuse `client.py::_normalize_points()` (import it,
  do not duplicate) for defending against malformed/nested `points` shapes — this
  is exactly as important for Cloudflare's smaller model as it was for Claude,
  per the approved spec's explicit rationale.
- No automatic fallback between providers on error, in either direction.
- `SessionState.setFeedbackProvider()` must NOT auto-retrigger `requestFeedback()`
  — this is a deliberate deviation from `setTolerancePreset()`'s auto-rescore
  behavior, since feedback calls are billable and only ever fire on an explicit
  user tap (see the existing `requestFeedback()` doc comment in
  `session_state.dart`).
- Persistence follows the exact `TolerancePreset` pattern: `SharedPreferences`,
  loaded via an explicit method called from `main.dart`'s `create:` callback
  (fire-and-forget), never from `SessionState`'s constructor.

---

### Task 1: Backend — Cloudflare-Client-Kernlogik (`backend/feedback/cloudflare_client.py`)

**Files:**
- Modify: `backend/config.py`
- Modify: `.env.example`
- Modify: `requirements.txt`
- Create: `backend/feedback/cloudflare_client.py`
- Test: `tests/test_feedback.py`

**Interfaces:**
- Consumes: `client.py::_normalize_points(points: Any) -> list[dict]` (already
  exists, public within the `backend.feedback.client` module — import it as
  `from backend.feedback.client import _normalize_points`).
- Produces: `CloudflareWorkersAIClient(account_id: str, api_token: str,
  http_client: httpx.Client | None = None)` with a `.create(*, model: str,
  messages: list[dict], tools: list[dict]) -> dict` method; module-level
  `request_feedback_points(client, model: str, prompt_text: str, catalog_ids:
  list[str]) -> list[dict]` (same signature shape as `client.py`'s function, for
  Task 2 to call symmetrically).

- [ ] **Step 1: Add Cloudflare constants to config.py**

Read `backend/config.py` first to find the exact current lines around
`ANTHROPIC_API_KEY`/`ANTHROPIC_MODEL` (search for `ANTHROPIC_MODEL = os.environ`).
Append right after that line:

```python
CLOUDFLARE_ACCOUNT_ID = os.environ.get("CLOUDFLARE_ACCOUNT_ID", "")
CLOUDFLARE_API_TOKEN = os.environ.get("CLOUDFLARE_API_TOKEN", "")
CLOUDFLARE_MODEL = "@cf/qwen/qwen3-30b-a3b-fp8"
```

- [ ] **Step 2: Update .env.example**

Append to `.env.example`, after the existing `ANTHROPIC_MODEL=claude-sonnet-5`
line and before the `CORS_ALLOWED_ORIGINS` section:

```
# Optional: Cloudflare Workers AI als alternativer Feedback-Provider (waehlbar in
# der App). Account-ID findest du im Cloudflare-Dashboard, API-Token unter
# "Manage Account" -> "API Tokens" (Berechtigung "Workers AI: Read" reicht).
CLOUDFLARE_ACCOUNT_ID=
CLOUDFLARE_API_TOKEN=
```

- [ ] **Step 3: Add httpx to requirements.txt**

Add `httpx>=0.27` to `requirements.txt`, in the "Ab Phase 3 ... Phase 6" block
next to `anthropic>=0.40` (same section, since this is also a Phase-6 external-API
dependency).

- [ ] **Step 4: Write the failing tests**

Read `tests/test_feedback.py`'s existing `_FakeMessagesClient` class (search for
`class _FakeMessagesClient`) first, to match its exact style. Append to
`tests/test_feedback.py`, after the last `test_request_feedback_points_*` test
(search for `def test_request_feedback_points_unwraps_doubly_nested_points` to
find the end of that block) and before
`def test_request_feedback_points_passes_catalog_ids_as_enum_in_tool_schema`:

```python
from backend.feedback.cloudflare_client import (
    CloudflareWorkersAIClient,
    request_feedback_points as cloudflare_request_feedback_points,
)


class _FakeCloudflareClient:
    def __init__(self, tool_calls=None, raise_error=None):
        self._tool_calls = tool_calls if tool_calls is not None else []
        self._raise_error = raise_error
        self.last_kwargs = None

    def create(self, **kwargs):
        self.last_kwargs = kwargs
        if self._raise_error:
            raise self._raise_error
        return {
            "result": {"tool_calls": self._tool_calls},
            "success": True,
            "errors": [],
            "messages": [],
        }


def test_cloudflare_request_feedback_points_extracts_points_from_tool_call():
    fake = _FakeCloudflareClient(
        tool_calls=[{"name": "return_feedback_points", "arguments": {"points": [{"problem": "P", "uebung_id": "a"}]}}]
    )
    points = cloudflare_request_feedback_points(fake, "@cf/qwen/qwen3-30b-a3b-fp8", "prompt", ["a"])
    assert points == [{"problem": "P", "uebung_id": "a"}]


def test_cloudflare_request_feedback_points_parses_stringified_arguments():
    # Workers AI's "arguments" ist laut Dokumentation vom Typ "unknown" - manche
    # Modelle liefern es als JSON-String statt als bereits geparstes Objekt.
    import json

    fake = _FakeCloudflareClient(
        tool_calls=[{
            "name": "return_feedback_points",
            "arguments": json.dumps({"points": [{"problem": "P", "uebung_id": "a"}]}),
        }]
    )
    points = cloudflare_request_feedback_points(fake, "@cf/qwen/qwen3-30b-a3b-fp8", "prompt", ["a"])
    assert points == [{"problem": "P", "uebung_id": "a"}]


def test_cloudflare_request_feedback_points_reuses_normalize_points_for_malformed_shapes():
    # Derselbe doppelt verschachtelte Fall wie bei Anthropic live beobachtet -
    # beweist, dass _normalize_points() tatsaechlich wiederverwendet wird, nicht
    # eine zweite, unabhaengige (und potenziell abweichende) Kopie existiert.
    real_points = [{"problem": "P1", "uebung_id": "a"}, {"problem": "P2", "uebung_id": "b"}]
    fake = _FakeCloudflareClient(
        tool_calls=[{"name": "return_feedback_points", "arguments": {"points": [{"points": real_points}]}}]
    )
    points = cloudflare_request_feedback_points(fake, "@cf/qwen/qwen3-30b-a3b-fp8", "prompt", ["a", "b"])
    assert points == real_points


def test_cloudflare_request_feedback_points_raises_when_no_tool_calls_present():
    fake = _FakeCloudflareClient(tool_calls=[])
    with pytest.raises(RuntimeError):
        cloudflare_request_feedback_points(fake, "@cf/qwen/qwen3-30b-a3b-fp8", "prompt", ["a"])


def test_cloudflare_request_feedback_points_passes_catalog_ids_as_enum_in_tool_schema():
    fake = _FakeCloudflareClient(tool_calls=[{"name": "return_feedback_points", "arguments": {"points": []}}])
    cloudflare_request_feedback_points(fake, "@cf/qwen/qwen3-30b-a3b-fp8", "prompt", ["a", "b"])
    schema = fake.last_kwargs["tools"][0]["function"]["parameters"]
    assert schema["properties"]["points"]["items"]["properties"]["uebung_id"]["enum"] == ["a", "b"]


def test_cloudflare_workers_ai_client_posts_to_correct_url_with_bearer_token(monkeypatch):
    captured = {}

    class _FakeHttpxClient:
        def post(self, url, headers=None, json=None, **kwargs):
            captured["url"] = url
            captured["headers"] = headers
            captured["json"] = json

            class _Resp:
                def raise_for_status(self):
                    pass

                def json(self):
                    return {"result": {"tool_calls": []}, "success": True, "errors": [], "messages": []}

            return _Resp()

    client = CloudflareWorkersAIClient(
        account_id="acct123", api_token="tok456", http_client=_FakeHttpxClient()
    )
    client.create(model="@cf/qwen/qwen3-30b-a3b-fp8", messages=[{"role": "user", "content": "hi"}], tools=[])

    assert captured["url"] == "https://api.cloudflare.com/client/v4/accounts/acct123/ai/run/@cf/qwen/qwen3-30b-a3b-fp8"
    assert captured["headers"]["Authorization"] == "Bearer tok456"
    assert captured["json"]["messages"] == [{"role": "user", "content": "hi"}]
```

- [ ] **Step 5: Run tests to verify they fail**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/test_feedback.py -k cloudflare -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'backend.feedback.cloudflare_client'`.

- [ ] **Step 6: Implement cloudflare_client.py**

Create `backend/feedback/cloudflare_client.py`:

```python
"""Kapselt den Cloudflare-Workers-AI-Aufruf per REST + Function-Calling, als
Alternative zu client.py (Anthropic). Gleiche Garantie wie bei Anthropic:
uebung_id ist im Tool-Schema als Enum auf die tatsaechlichen Katalog-IDs
beschraenkt. Nutzt _normalize_points() aus client.py wieder, statt sie zu
duplizieren - ein kleineres Modell wie Qwen3-30B-A3B haelt sich vermutlich noch
weniger zuverlaessig ans Schema als Claude (siehe die dort dokumentierten,
live beobachteten Fehlformen)."""

from __future__ import annotations

import json
from typing import Any, Protocol

import httpx

from backend.feedback.client import _normalize_points

_TOOL_NAME = "return_feedback_points"


class CloudflareMessagesClient(Protocol):
    """Minimale Schnittstelle, die request_feedback_points von einem Cloudflare-
    Client braucht - injizierbar fuer Tests (siehe test_feedback.py:
    _FakeCloudflareClient). generate.py uebergibt eine echte
    CloudflareWorkersAIClient-Instanz."""

    def create(self, **kwargs: Any) -> dict: ...


class CloudflareWorkersAIClient:
    """Ruft POST .../accounts/{account_id}/ai/run/{model} auf. Account-ID und
    API-Token werden beim Bau gebacken (analog anthropic.Anthropic(api_key=...)),
    http_client ist injizierbar fuer Tests (kein echter Netzwerkzugriff)."""

    def __init__(
        self, account_id: str, api_token: str, http_client: httpx.Client | None = None,
    ) -> None:
        self._account_id = account_id
        self._api_token = api_token
        self._http_client = http_client or httpx.Client(timeout=30.0)

    def create(self, *, model: str, messages: list[dict], tools: list[dict]) -> dict:
        url = f"https://api.cloudflare.com/client/v4/accounts/{self._account_id}/ai/run/{model}"
        response = self._http_client.post(
            url,
            headers={"Authorization": f"Bearer {self._api_token}"},
            json={"messages": messages, "tools": tools},
        )
        response.raise_for_status()
        return response.json()


def _tool_schema_openai(catalog_ids: list[str]) -> dict:
    return {
        "type": "function",
        "function": {
            "name": _TOOL_NAME,
            "description": "Gibt bis zu 3 priorisierte Feedback-Punkte fuer eine Gesangsaufnahme zurueck.",
            "parameters": {
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
        },
    }


def request_feedback_points(
    client: CloudflareMessagesClient,
    model: str,
    prompt_text: str,
    catalog_ids: list[str],
) -> list[dict]:
    """Ruft client.create() per Function-Calling auf und gibt die rohen
    {problem, uebung_id, wiederholungsaufgabe?}-Punkte zurueck - gleiche
    Rueckgabeform wie client.py::request_feedback_points (Anthropic), damit
    generate.py beide Provider identisch weiterverarbeiten kann. Wirft
    RuntimeError, wenn die Antwort keinen verwertbaren tool_calls-Eintrag
    enthaelt."""
    response = client.create(
        model=model,
        messages=[{"role": "user", "content": prompt_text}],
        tools=[_tool_schema_openai(catalog_ids)],
    )
    tool_calls = response.get("result", {}).get("tool_calls") or []
    for call in tool_calls:
        if call.get("name") != _TOOL_NAME:
            continue
        arguments = call.get("arguments", {})
        # Cloudflares eigene Dokumentation deklariert "arguments" als Typ
        # "unknown" - je nach Modell kann es ein bereits geparstes Objekt oder
        # ein JSON-kodierter String sein. Ein verschachteltes "function"-Feld
        # (OpenAI-Kompatibilitaetsformat) wird ebenfalls defensiv abgefangen,
        # falls Cloudflare das Antwortformat je angleicht.
        if "function" in call and "arguments" in call["function"]:
            arguments = call["function"]["arguments"]
        if isinstance(arguments, str):
            try:
                arguments = json.loads(arguments)
            except json.JSONDecodeError as exc:
                raise RuntimeError(
                    "Cloudflare-Antwort enthielt ein nicht parsbares arguments-Feld."
                ) from exc
        points = arguments.get("points", []) if isinstance(arguments, dict) else arguments
        return _normalize_points(points)
    raise RuntimeError("Cloudflare-Antwort enthielt keinen verwertbaren tool_calls-Eintrag.")
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/test_feedback.py -v`
Expected: all tests PASS, including the 6 new Cloudflare tests and every
pre-existing test in the file.

- [ ] **Step 8: Run the full backend test suite for regressions**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/ -v`
Expected: all tests PASS.

- [ ] **Step 9: Commit**

```bash
git add backend/config.py .env.example requirements.txt backend/feedback/cloudflare_client.py tests/test_feedback.py
git commit -m "feat: add Cloudflare Workers AI client for feedback generation"
```

---

### Task 2: Backend — Orchestrator- & API-Integration (`backend/feedback/generate.py`, `backend/api/routes.py`)

**Files:**
- Modify: `backend/feedback/generate.py`
- Modify: `backend/api/routes.py`
- Test: `tests/test_feedback.py`

**Interfaces:**
- Consumes: `cloudflare_client.request_feedback_points(client, model, prompt_text,
  catalog_ids) -> list[dict]` and `cloudflare_client.CloudflareWorkersAIClient`
  from Task 1.
- Produces: `generate_feedback(score_result, provider="anthropic",
  messages_client_factory=None, cloudflare_client_factory=None) -> dict` (new
  `provider`/`cloudflare_client_factory` params, same return shape as before);
  `FeedbackRequest.provider: str = "anthropic"` in `routes.py`.

- [ ] **Step 1: Write the failing tests**

Read `tests/test_feedback.py`'s existing `generate_feedback`-related tests first
(search for `def test_generate_feedback_raises_when_api_key_missing`) to match
style. Append to `tests/test_feedback.py`, after the last
`test_generate_feedback_*` test (search for
`def test_generate_feedback_jump_to_t_is_none_when_no_note_matches` to find the
end of that block):

```python
def test_generate_feedback_uses_cloudflare_when_provider_is_cloudflare(monkeypatch):
    monkeypatch.setattr("backend.feedback.generate.CLOUDFLARE_ACCOUNT_ID", "acct123")
    monkeypatch.setattr("backend.feedback.generate.CLOUDFLARE_API_TOKEN", "tok456")
    notes = [_note(0, timing_classification="too_late", timing_deviation_ms=250.0, sung_t=1.0)]
    score_result = _score_result(notes)
    score_result["summary"]["problem_tags"] = ["timingprobleme"]
    fake = _FakeCloudflareClient(
        tool_calls=[{
            "name": "return_feedback_points",
            "arguments": {"points": [{"problem": "Timing daneben", "uebung_id": "timingprobleme"}]},
        }]
    )
    result = generate_feedback(
        score_result, provider="cloudflare", cloudflare_client_factory=lambda: fake,
    )
    assert result["points"][0]["problem"] == "Timing daneben"
    assert fake.last_kwargs["model"] == "@cf/qwen/qwen3-30b-a3b-fp8"


def test_generate_feedback_raises_when_cloudflare_credentials_missing(monkeypatch):
    monkeypatch.setattr("backend.feedback.generate.CLOUDFLARE_ACCOUNT_ID", "")
    monkeypatch.setattr("backend.feedback.generate.CLOUDFLARE_API_TOKEN", "")
    notes = [_note(0, timing_classification="too_late", timing_deviation_ms=250.0)]
    score_result = _score_result(notes)
    score_result["summary"]["problem_tags"] = ["timingprobleme"]
    with pytest.raises(FeedbackUnavailableError):
        generate_feedback(score_result, provider="cloudflare")


def test_generate_feedback_raises_on_unknown_provider():
    notes = [_note(0, timing_classification="too_late", timing_deviation_ms=250.0)]
    score_result = _score_result(notes)
    score_result["summary"]["problem_tags"] = ["timingprobleme"]
    with pytest.raises(FeedbackUnavailableError):
        generate_feedback(score_result, provider="does_not_exist")


def test_generate_feedback_still_defaults_to_anthropic(monkeypatch):
    monkeypatch.setattr("backend.feedback.generate.ANTHROPIC_API_KEY", "dummy-key")
    notes = [_note(0, timing_classification="too_late", timing_deviation_ms=250.0)]
    score_result = _score_result(notes)
    score_result["summary"]["problem_tags"] = ["timingprobleme"]
    fake = _FakeMessagesClient(points=[{"problem": "Timing", "uebung_id": "timingprobleme"}])
    result = generate_feedback(score_result, messages_client_factory=lambda: fake)
    assert result["points"][0]["problem"] == "Timing"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/test_feedback.py -k "cloudflare or unknown_provider" -v`
Expected: FAIL — `generate_feedback()` doesn't accept a `provider` keyword yet
(`TypeError: generate_feedback() got an unexpected keyword argument 'provider'`).

- [ ] **Step 3: Wire provider dispatch into generate.py**

In `backend/feedback/generate.py`:

Add to the imports, right after the existing
`from backend.config import ANTHROPIC_API_KEY, ANTHROPIC_MODEL` line:

```python
from backend.config import CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_API_TOKEN, CLOUDFLARE_MODEL
from backend.feedback.cloudflare_client import CloudflareWorkersAIClient
from backend.feedback.cloudflare_client import request_feedback_points as request_feedback_points_cloudflare
```

Replace the `generate_feedback` function signature and its body up to (but not
including) the `used_notes: set[int] = set()` line:

```python
def generate_feedback(
    score_result: dict,
    provider: str = "anthropic",
    messages_client_factory: Callable[[], Any] | None = None,
    cloudflare_client_factory: Callable[[], Any] | None = None,
) -> dict:
    """Liefert {"points": [...]} mit bis zu 3 Punkten (problem, technik, uebung,
    wiederholungsaufgabe, jump_to_t). Leere Liste, wenn score_result["summary"]
    ["problem_tags"] leer ist (kein API-Aufruf noetig). provider ist "anthropic"
    (Default) oder "cloudflare" - waehlt, welcher externe Anbieter fuer die
    Feedback-Generierung genutzt wird (siehe
    docs/superpowers/specs/2026-08-08-cloudflare-feedback-provider-design.md).
    Wirft FeedbackUnavailableError, wenn die noetigen Zugangsdaten fuer den
    gewaehlten Provider fehlen, der Provider unbekannt ist, oder der externe
    Aufruf fehlschlaegt. jump_to_t ist die Position (Sekunden) in der eigenen
    Aufnahme der ersten unverbrauchten Note dieser Kategorie mit Zeitstelle,
    oder None. messages_client_factory/cloudflare_client_factory sind
    injizierbar fuer Tests (siehe test_feedback.py) - Default baut jeweils
    einen echten Client fuer den gewaehlten Provider."""
    if not score_result["summary"]["problem_tags"]:
        return {"points": []}

    if provider == "anthropic":
        if not ANTHROPIC_API_KEY:
            raise FeedbackUnavailableError(_UNAVAILABLE_MESSAGE)
        if messages_client_factory is None:
            messages_client_factory = lambda: anthropic.Anthropic(api_key=ANTHROPIC_API_KEY).messages
    elif provider == "cloudflare":
        if not CLOUDFLARE_ACCOUNT_ID or not CLOUDFLARE_API_TOKEN:
            raise FeedbackUnavailableError(_UNAVAILABLE_MESSAGE)
        if cloudflare_client_factory is None:
            cloudflare_client_factory = lambda: CloudflareWorkersAIClient(
                CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_API_TOKEN
            )
    else:
        raise FeedbackUnavailableError(_UNAVAILABLE_MESSAGE)

    catalog = load_catalog()
    context = build_prompt_context(score_result)
    prompt_text = build_prompt_text(context)

    try:
        if provider == "anthropic":
            raw_points = request_feedback_points(
                messages_client_factory(), ANTHROPIC_MODEL, prompt_text, catalog_ids(catalog)
            )
        else:
            raw_points = request_feedback_points_cloudflare(
                cloudflare_client_factory(), CLOUDFLARE_MODEL, prompt_text, catalog_ids(catalog)
            )
    except Exception as exc:
        raise FeedbackUnavailableError(_UNAVAILABLE_MESSAGE) from exc
```

(The rest of the function — `used_notes`/`points`/the `for raw in raw_points[:3]`
loop and the `return {"points": points}` — stays byte-for-byte unchanged, since
`raw_points` has the same shape regardless of provider.)

- [ ] **Step 4: Wire the provider field into the API request**

In `backend/api/routes.py`, find the `FeedbackRequest` class (search for
`class FeedbackRequest`) and change it to:

```python
class FeedbackRequest(BaseModel):
    score: dict  # ScoreResult, wie von /api/score unter "score" zurueckgegeben
    provider: str = "anthropic"
```

In the `feedback()` function, change the `generate_feedback(body.score)` call to:

```python
result = generate_feedback(body.score, provider=body.provider)
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/test_feedback.py -v`
Expected: all tests PASS, including the 4 new tests.

- [ ] **Step 6: Run the full backend test suite for regressions**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/ -v`
Expected: all tests PASS.

- [ ] **Step 7: Commit**

```bash
git add backend/feedback/generate.py backend/api/routes.py tests/test_feedback.py
git commit -m "feat: dispatch feedback generation between Anthropic and Cloudflare by provider"
```

---

### Task 3: Mobile — FeedbackProvider-Modell & SessionState-Integration

**Files:**
- Create: `mobile/lib/models/feedback_provider.dart`
- Modify: `mobile/lib/api/feedback_api.dart`
- Modify: `mobile/lib/state/session_state.dart`
- Modify: `mobile/lib/main.dart`
- Test: `mobile/test/session_state_test.dart`

**Interfaces:**
- Consumes: nothing new from earlier tasks (this task only needs the backend's
  `/api/feedback` to accept an extra `"provider"` JSON field, which Task 2 already
  shipped and is backward-compatible via its default value).
- Produces: `FeedbackProvider` enum (`anthropic`, `cloudflare`) with `.apiValue`/
  `.label`/`FeedbackProvider.fromApiValue(String?)`; `SessionState.feedbackProvider`,
  `SessionState.setFeedbackProvider(FeedbackProvider)`,
  `SessionState.loadPersistedFeedbackProvider()` — for Task 4's UI widget to bind
  to.

- [ ] **Step 1: Create the FeedbackProvider enum**

Read `mobile/lib/models/tolerance_preset.dart` first to match its exact style.
Create `mobile/lib/models/feedback_provider.dart`:

```dart
/// Waehlbarer Anbieter fuer die Claude-Feedback-Generierung (Phase 6, siehe
/// docs/superpowers/specs/2026-08-08-cloudflare-feedback-provider-design.md).
/// Eigene Datei (statt inline in session_state.dart wie ReferenceSource), weil
/// sowohl SessionState als auch FeedbackApi dieses Enum brauchen und FeedbackApi
/// SessionState nicht importieren darf (Zirkelbezug) - gleiche Begruendung wie
/// bei TolerancePreset.
enum FeedbackProvider {
  anthropic,
  cloudflare;

  String get apiValue => switch (this) {
        FeedbackProvider.anthropic => 'anthropic',
        FeedbackProvider.cloudflare => 'cloudflare',
      };

  String get label => switch (this) {
        FeedbackProvider.anthropic => 'Claude',
        FeedbackProvider.cloudflare => 'Cloudflare',
      };

  static FeedbackProvider? fromApiValue(String? value) {
    for (final provider in FeedbackProvider.values) {
      if (provider.apiValue == value) return provider;
    }
    return null;
  }
}
```

- [ ] **Step 2: Write the failing tests for SessionState**

Read `mobile/test/session_state_test.dart`'s existing `'SessionState
Toleranz-Preset'` group first (search for `group('SessionState Toleranz-Preset'`)
to match its exact style, including the `_buildSession()` helper and
`_FakeApiClient`. Append a new group right after that group's closing `});`
(before the file's final closing `}`):

```dart
  group('SessionState Feedback-Provider', () {
    test('feedbackProvider startet mit FeedbackProvider.anthropic', () {
      final session = _buildSession();
      expect(session.feedbackProvider, FeedbackProvider.anthropic);
    });

    test('setFeedbackProvider setzt den Wert und sendet ihn bei requestFeedback() mit',
        () async {
      final client = _FakeApiClient();
      final session = SessionState(
        midiApi: MidiApi(client),
        audioApi: AudioApi(client),
        syncApi: SyncApi(client),
        scoreApi: ScoreApi(client),
        feedbackApi: FeedbackApi(client),
      );
      session.setReferenceSource(ReferenceSource.midi);
      session.midiSessionId = 'sess-1';
      session.selectedTrackIndex = 0;
      await session.analyzeAudio(Uint8List.fromList([1, 2, 3]), 'gesang.wav');
      await session.score();

      await session.setFeedbackProvider(FeedbackProvider.cloudflare);
      expect(session.feedbackProvider, FeedbackProvider.cloudflare);

      await session.requestFeedback();
      expect(client.lastPostJsonBody?['provider'], 'cloudflare');
    });

    test('setFeedbackProvider loest KEIN automatisches requestFeedback() aus '
        '(Feedback-Aufrufe sind kostenpflichtig und nur manuell)', () async {
      final client = _FakeApiClient();
      final session = SessionState(
        midiApi: MidiApi(client),
        audioApi: AudioApi(client),
        syncApi: SyncApi(client),
        scoreApi: ScoreApi(client),
        feedbackApi: FeedbackApi(client),
      );
      session.setReferenceSource(ReferenceSource.midi);
      session.midiSessionId = 'sess-1';
      session.selectedTrackIndex = 0;
      await session.analyzeAudio(Uint8List.fromList([1, 2, 3]), 'gesang.wav');
      await session.score();

      await session.setFeedbackProvider(FeedbackProvider.cloudflare);

      expect(client.feedbackCallCount, 0);
      expect(session.feedbackStatus, LoadStatus.idle);
    });

    test('setFeedbackProvider persistiert die Wahl, eine neue SessionState-Instanz '
        'laedt sie per loadPersistedFeedbackProvider() zurueck', () async {
      final sessionA = _buildSession();
      await sessionA.setFeedbackProvider(FeedbackProvider.cloudflare);

      final sessionB = _buildSession();
      expect(sessionB.feedbackProvider, FeedbackProvider.anthropic,
          reason: 'vor dem Laden noch der Default');
      await sessionB.loadPersistedFeedbackProvider();

      expect(sessionB.feedbackProvider, FeedbackProvider.cloudflare);
    });

    test('loadPersistedFeedbackProvider() aendert nichts, wenn nie etwas '
        'gespeichert wurde', () async {
      SharedPreferences.setMockInitialValues({});
      final session = _buildSession();

      await session.loadPersistedFeedbackProvider();

      expect(session.feedbackProvider, FeedbackProvider.anthropic);
    });
  });
```

Add the import at the top of the file, next to the existing
`import 'package:singing_feedback_mobile/models/tolerance_preset.dart';` line:

```dart
import 'package:singing_feedback_mobile/models/feedback_provider.dart';
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd mobile && flutter test test/session_state_test.dart --plain-name "Feedback-Provider"`
Expected: FAIL — compile error, `SessionState` has no `feedbackProvider` getter/
`setFeedbackProvider`/`loadPersistedFeedbackProvider` yet.

- [ ] **Step 4: Add the provider parameter to FeedbackApi**

In `mobile/lib/api/feedback_api.dart`, change `requestFeedback`:

```dart
import '../models/feedback_provider.dart';
import '../models/feedback_result.dart';
import 'api_client.dart';

/// Ruft POST /api/feedback auf (backend/api/routes.py::feedback) und liefert das
/// geparste Feedback. Nimmt das bereits vom Server erhaltene ScoreResult-JSON
/// entgegen (via ScoreResult.toJson()) - keine Neuberechnung noetig.
class FeedbackApi {
  final ApiClient _client;

  FeedbackApi(this._client);

  Future<FeedbackResult> requestFeedback(
    Map<String, dynamic> scoreJson,
    FeedbackProvider provider,
  ) async {
    final json = await _client.postJson(
      '/api/feedback',
      {'score': scoreJson, 'provider': provider.apiValue},
    );
    return FeedbackResult.fromJson(json['feedback'] as Map<String, dynamic>);
  }
}
```

- [ ] **Step 5: Add feedbackProvider state to SessionState**

Read `mobile/lib/state/session_state.dart` in full first to find the exact
current line numbers (they will have shifted from any reference elsewhere) for:
the `_tolerancePresetPrefsKey` constant, the `tolerancePreset` field, the
`setTolerancePreset`/`loadPersistedTolerancePreset` methods, and the
`requestFeedback()` method.

Add a new prefs-key constant right after the existing
`const String _tolerancePresetPrefsKey = 'tolerance_preset';` line:

```dart
const String _feedbackProviderPrefsKey = 'feedback_provider';
```

Add the import at the top of the file, next to the existing
`import '../models/tolerance_preset.dart';`-style imports:

```dart
import '../models/feedback_provider.dart';
```

Add a new field right after the existing `TolerancePreset tolerancePreset =
TolerancePreset.normal;` field declaration:

```dart
  /// Waehlbarer Anbieter fuer die Feedback-Generierung, Default aus dem
  /// Konstruktor, danach ggf. asynchron per loadPersistedFeedbackProvider()
  /// nachgeladen (siehe dort) - gleiches Muster wie tolerancePreset.
  FeedbackProvider feedbackProvider = FeedbackProvider.anthropic;
```

Add two new methods right after the existing `loadPersistedTolerancePreset()`
method:

```dart
  Future<void> setFeedbackProvider(FeedbackProvider provider) async {
    feedbackProvider = provider;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_feedbackProviderPrefsKey, provider.apiValue);
    // Bewusst KEIN automatisches requestFeedback() hier, anders als
    // setTolerancePreset()'s Auto-Rescore: ein Feedback-Aufruf ist
    // kostenpflichtig und soll ausschliesslich per expliziten Nutzer-Tap
    // ausgeloest werden (siehe Kommentar an requestFeedback() unten).
  }

  /// Laedt einen zuvor gespeicherten Feedback-Provider (falls vorhanden) und
  /// wendet ihn an - bewusst NICHT im Konstruktor, sondern nur von main.dart
  /// nach dem Bauen dieser SessionState aufgerufen (fire-and-forget), gleiches
  /// Prinzip wie loadPersistedTolerancePreset().
  Future<void> loadPersistedFeedbackProvider() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = FeedbackProvider.fromApiValue(prefs.getString(_feedbackProviderPrefsKey));
    if (stored != null && stored != feedbackProvider) {
      feedbackProvider = stored;
      notifyListeners();
    }
  }
```

In the existing `requestFeedback()` method, change the line
`feedbackResult = await feedbackApi.requestFeedback(scoreResult!.toJson());` to:

```dart
      feedbackResult = await feedbackApi.requestFeedback(scoreResult!.toJson(), feedbackProvider);
```

- [ ] **Step 6: Wire loadPersistedFeedbackProvider into main.dart**

In `mobile/lib/main.dart`, add right after the existing
`unawaited(session.loadPersistedTolerancePreset());` line:

```dart
        unawaited(session.loadPersistedFeedbackProvider());
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `cd mobile && flutter test test/session_state_test.dart`
Expected: all tests PASS, including the 5 new Feedback-Provider tests.

- [ ] **Step 8: Run the full mobile test suite for regressions**

Run: `cd mobile && flutter test`
Expected: all tests PASS.

- [ ] **Step 9: Commit**

```bash
git add mobile/lib/models/feedback_provider.dart mobile/lib/api/feedback_api.dart mobile/lib/state/session_state.dart mobile/lib/main.dart mobile/test/session_state_test.dart
git commit -m "feat: add FeedbackProvider state to SessionState, thread through to /api/feedback"
```

---

### Task 4: Mobile — FeedbackProviderControl-UI

**Files:**
- Create: `mobile/lib/widgets/feedback_provider_control.dart`
- Modify: `mobile/lib/screens/home_screen.dart`
- Test: Create `mobile/test/feedback_provider_control_test.dart`

**Interfaces:**
- Consumes: `FeedbackProvider` enum and `SessionState.feedbackProvider`/
  `setFeedbackProvider` from Task 3.
- Produces: no new public interface — this is the final, UI-facing task.

- [ ] **Step 1: Write the failing test**

Read `mobile/test/tolerance_preset_control_test.dart` first to match its exact
style. Create `mobile/test/feedback_provider_control_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singing_feedback_mobile/models/feedback_provider.dart';
import 'package:singing_feedback_mobile/widgets/feedback_provider_control.dart';

void main() {
  testWidgets('zeigt beide Provider-Labels an', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FeedbackProviderControl(value: FeedbackProvider.anthropic, onChanged: (_) {}),
      ),
    ));

    expect(find.text('Claude'), findsOneWidget);
    expect(find.text('Cloudflare'), findsOneWidget);
  });

  testWidgets('Tippen auf einen anderen Provider ruft onChanged mit dem richtigen Wert auf',
      (tester) async {
    FeedbackProvider? changedTo;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FeedbackProviderControl(
          value: FeedbackProvider.anthropic,
          onChanged: (provider) => changedTo = provider,
        ),
      ),
    ));

    await tester.tap(find.text('Cloudflare'));
    await tester.pump();

    expect(changedTo, FeedbackProvider.cloudflare);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mobile && flutter test test/feedback_provider_control_test.dart`
Expected: FAIL — `ModuleNotFoundError`-style compile error, the widget file
doesn't exist yet.

- [ ] **Step 3: Implement FeedbackProviderControl**

Read `mobile/lib/widgets/tolerance_preset_control.dart` first to match its exact
style. Create `mobile/lib/widgets/feedback_provider_control.dart`:

```dart
import 'package:flutter/material.dart';

import '../models/feedback_provider.dart';

/// Waehlt den Anbieter fuer die Feedback-Generierung (siehe
/// docs/superpowers/specs/2026-08-08-cloudflare-feedback-provider-design.md).
/// Reines Props-Widget (kein direkter SessionState-Zugriff), gleiches Muster
/// wie TolerancePresetControl.
class FeedbackProviderControl extends StatelessWidget {
  final FeedbackProvider value;
  final ValueChanged<FeedbackProvider> onChanged;

  const FeedbackProviderControl({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Text('Anbieter:'),
        const SizedBox(width: 12),
        SegmentedButton<FeedbackProvider>(
          segments: FeedbackProvider.values
              .map((provider) => ButtonSegment(value: provider, label: Text(provider.label)))
              .toList(),
          selected: {value},
          onSelectionChanged: (selection) => onChanged(selection.first),
        ),
      ],
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mobile && flutter test test/feedback_provider_control_test.dart`
Expected: both tests PASS.

- [ ] **Step 5: Wire FeedbackProviderControl into home_screen.dart**

Read `mobile/lib/screens/home_screen.dart` first to find the exact current lines
around the `Text('5. Feedback', ...)` heading (search for that exact string —
line numbers may have shifted). Add the import at the top, next to the existing
`import '../widgets/tolerance_preset_control.dart';`-style imports:

```dart
import '../widgets/feedback_provider_control.dart';
```

Change the block:

```dart
            Text('5. Feedback', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            FeedbackSection(session: session),
```

to:

```dart
            Text('5. Feedback', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            FeedbackProviderControl(
              value: session.feedbackProvider,
              onChanged: (provider) => session.setFeedbackProvider(provider),
            ),
            FeedbackSection(session: session),
```

- [ ] **Step 6: Run the full mobile test suite for regressions**

Run: `cd mobile && flutter test`
Expected: all tests PASS.

- [ ] **Step 7: Commit**

```bash
git add mobile/lib/widgets/feedback_provider_control.dart mobile/lib/screens/home_screen.dart mobile/test/feedback_provider_control_test.dart
git commit -m "feat: add FeedbackProviderControl selector above the feedback section"
```

---

## Self-Review Notes

- **Spec coverage:** Backend Cloudflare client + config/env/requirements (Task 1),
  orchestrator dispatch + API field (Task 2), mobile model + state + persistence
  (Task 3), mobile UI (Task 4) are all covered. The spec's explicit "no
  auto-retrigger on provider change" deviation from the tolerance-preset pattern
  is implemented (Task 3, `setFeedbackProvider`) and has a dedicated negative test
  proving it. Out-of-scope items from the spec (auto-fallback between providers,
  a third/fourth provider, model-selection UI, server-side-only config) are
  untouched by every task.
- **Type consistency checked:** `cloudflare_client.request_feedback_points`'s
  return shape (Task 1) matches exactly what `client.py`'s Anthropic version
  returns and what Task 2's `generate_feedback` treats identically regardless of
  provider; `FeedbackProvider.apiValue` (Task 3) matches the `"provider"` string
  Task 2's `FeedbackRequest`/`generate_feedback` expect (`"anthropic"`/
  `"cloudflare"`); `CloudflareWorkersAIClient`'s constructor signature (Task 1)
  matches exactly how Task 2's `generate_feedback` constructs it via
  `cloudflare_client_factory`.
- **Real-world API-shape caveat, worth flagging explicitly:** Task 1's
  `cloudflare_client.py::request_feedback_points` was written from Cloudflare's
  documented response schema (`result.tool_calls[i].name`/`.arguments`, not
  OpenAI's `.function.name`/`.function.arguments` nesting) cross-checked against
  two independent sources, but defensively also checks for a `"function"` sub-key
  as a fallback in case Cloudflare's actual live response differs from the
  documented shape (this project has hit real Anthropic-side documentation-vs-
  reality gaps before, e.g. this same day's `_normalize_points` bug). **Before
  trusting this feature end-to-end, do one real manual test against the live
  Workers AI API** (once `CLOUDFLARE_ACCOUNT_ID`/`CLOUDFLARE_API_TOKEN` are set in
  `.env`) and compare the actual response JSON against this assumption — if it
  differs, the fix is entirely inside `cloudflare_client.py::request_feedback_points`,
  nothing else in the plan depends on the exact shape.
- **No placeholders:** every step has literal code, not descriptions.

# Design: Cloudflare Workers AI als wählbarer Feedback-Provider

**Datum:** 2026-08-08
**Status:** Genehmigt, bereit für Plan

## Kontext

`backend/feedback/` (Phase 6) generiert bis zu 3 priorisierte Feedback-Punkte über
Anthropics Claude-API, per Tool-Use mit einem JSON-Schema, das `uebung_id` auf die
tatsächlichen Katalog-IDs beschränkt (siehe `backend/feedback/client.py`). Anthropic
ist bislang der einzige externe API-Anbieter im Projekt.

Ziel dieser Spec: **Cloudflare Workers AI** als zweiter, in der App **wählbarer**
Provider für dieselbe Feedback-Generierung — kein Ersatz für Anthropic, sondern eine
Alternative, ähnlich wie das bestehende Toleranz-Preset (Streng/Normal/Locker) eine
Auswahl im Scoring beeinflusst. Modell: `@cf/qwen/qwen3-30b-a3b-fp8`
(Mixture-of-Experts, 30B Gesamtparameter/3B aktiv pro Anfrage, 32K Kontext,
Function-Calling-fähig — mit dem Nutzer abgestimmt).

Direkter Anlass: im selben Live-Test-Zyklus wurde ein echter Bug in
`request_feedback_points()` gefunden und behoben — Claude hält sich beim
Tool-Use-Schema für `points` bei längeren Prompts nicht immer zuverlässig ans
deklarierte Array-Format (drei verschiedene Fehlformen live beobachtet, siehe
`backend/feedback/client.py::_normalize_points()`). Da Cloudflares Modell
(Qwen3-30B-A3B) deutlich kleiner ist als Claude Sonnet 5, ist bei diesem Provider mit
**mindestens genauso unzuverlässiger** Schema-Einhaltung zu rechnen — die neue
Cloudflare-Anbindung muss denselben Normalizer von Anfang an mitnutzen, nicht erst
nach dem ersten Live-Crash nachrüsten.

## Architektur

### 1. Backend: Cloudflare-Client (`backend/feedback/cloudflare_client.py`, neues Modul)

Rohe REST-Anfrage über `httpx` (bereits transitiv installiert, z. B. via
`anthropic`-SDK — wird zusätzlich explizit in `requirements.txt` aufgenommen, um
nicht von einer transitiven Abhängigkeit abzuhängen). Kein neues Paket wie `openai`
nötig.

```python
class CloudflareWorkersAIClient:
    """Kapselt POST .../ai/run/{model} - Account-ID und API-Token werden beim Bau
    gebacken (analog anthropic.Anthropic(api_key=...)), injizierbar fuer Tests."""

    def __init__(self, account_id: str, api_token: str, http_client: httpx.Client | None = None):
        ...

    def create(self, *, model: str, messages: list[dict], tools: list[dict]) -> dict:
        """POST https://api.cloudflare.com/client/v4/accounts/{account_id}/ai/run/{model},
        Authorization: Bearer {api_token}, gibt das geparste JSON zurueck."""
        ...
```

`_tool_schema_openai(catalog_ids)` — dieselbe fachliche Struktur wie
`client.py::_tool_schema`, aber im OpenAI-Function-Calling-Format (Workers AI nutzt
dieses Format, nicht Anthropics `input_schema`):

```python
{
    "type": "function",
    "function": {
        "name": "return_feedback_points",
        "description": "...",
        "parameters": {
            "type": "object",
            "properties": {
                "points": {
                    "type": "array", "maxItems": 3,
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
```

`request_feedback_points(client, model, prompt_text, catalog_ids) -> list[dict]`:
ruft `client.create(...)` auf, liest `response["result"]["tool_calls"][0]["function"]["arguments"]`
(bei Workers AI ein JSON-kodierter String, IMMER `json.loads()`-pflichtig — anders
als bei Anthropic, wo `block.input` schon geparst ankommt), reicht das Ergebnis durch
`client.py::_normalize_points()` (aus `client.py` importiert, **nicht dupliziert** —
siehe Kontext oben, wird hier genauso gebraucht wie bei Anthropic). Wirft
`RuntimeError`, wenn kein `tool_calls`-Eintrag vorhanden ist (analog zum
"kein tool_use-Block"-Fall bei Anthropic).

### 2. Backend: Orchestrator (`backend/feedback/generate.py`)

`generate_feedback()` bekommt einen neuen Parameter:

```python
def generate_feedback(
    score_result: dict,
    provider: str = "anthropic",
    messages_client_factory: Callable[[], Any] | None = None,
    cloudflare_client_factory: Callable[[], Any] | None = None,
) -> dict:
```

Nach dem bestehenden `problem_tags`-Leer-Check verzweigt die Funktion:

- `provider == "anthropic"` (Default): bestehender Pfad unverändert, prüft
  `ANTHROPIC_API_KEY`.
- `provider == "cloudflare"`: prüft `CLOUDFLARE_ACCOUNT_ID`/`CLOUDFLARE_API_TOKEN`
  (beide nötig, sonst `FeedbackUnavailableError`), baut per Default
  `CloudflareWorkersAIClient(CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_API_TOKEN)`, ruft
  `cloudflare_client.request_feedback_points(...)` mit `CLOUDFLARE_MODEL` auf.
- Unbekannter `provider`-Wert: `FeedbackUnavailableError` (gleiche Fehlermeldung,
  kein Sonderfall für den Client sichtbar).

Der Rest der Funktion (Katalog-Anreicherung, `_find_jump_to_t`, Rückgabeform) bleibt
**identisch** für beide Provider — `request_feedback_points()` liefert in beiden
Fällen dieselbe normalisierte `list[dict]`-Form, der Rest von `generate_feedback()`
kennt den Provider-Unterschied nicht mehr.

### 3. Backend: Konfiguration & API (`backend/config.py`, `backend/api/routes.py`)

```python
CLOUDFLARE_ACCOUNT_ID = os.environ.get("CLOUDFLARE_ACCOUNT_ID", "")
CLOUDFLARE_API_TOKEN = os.environ.get("CLOUDFLARE_API_TOKEN", "")
CLOUDFLARE_MODEL = "@cf/qwen/qwen3-30b-a3b-fp8"
```

(analog `ANTHROPIC_API_KEY`/`ANTHROPIC_MODEL`; `.env.example` bekommt die zwei neuen
Zeilen mit demselben "wird nie eingecheckt"-Kommentar.)

`FeedbackRequest` (in `routes.py`) bekommt ein neues Feld:

```python
class FeedbackRequest(BaseModel):
    score: dict
    provider: str = "anthropic"
```

`feedback()` reicht `body.provider` an `generate_feedback(...)` durch. Kein neuer
Fehlerpfad nötig — ein unbekannter `provider`-String läuft in
`generate_feedback()`s neuen `FeedbackUnavailableError`-Zweig, der schon vom
bestehenden `except FeedbackUnavailableError`-Handler als 503 behandelt wird.

### 4. Mobile: Provider-Enum (`mobile/lib/models/feedback_provider.dart`, neue Datei)

Eigene Datei, gleiche Begründung wie bei `TolerancePreset` (Zirkelbezug-Vermeidung
zwischen `SessionState` und `FeedbackApi`):

```dart
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

### 5. Mobile: UI & State (`mobile/lib/widgets/feedback_provider_control.dart`,
`mobile/lib/state/session_state.dart`, `mobile/lib/api/feedback_api.dart`,
`mobile/lib/screens/home_screen.dart`)

Neues `FeedbackProviderControl`, exaktes Widget-Muster wie
`TolerancePresetControl` (`SegmentedButton<FeedbackProvider>`, `value`/`onChanged`-Props,
kein direkter `SessionState`-Zugriff).

`SessionState`:
- `FeedbackProvider feedbackProvider = FeedbackProvider.anthropic;`
- `Future<void> setFeedbackProvider(FeedbackProvider provider)`: setzt den Wert,
  `notifyListeners()`, persistiert über `SharedPreferences` (Key
  `'feedback_provider'`, gleiches Muster wie `_tolerancePresetPrefsKey`). **Kein**
  automatisches Neu-Anfordern von Feedback (anders als beim Toleranz-Preset, das
  automatisch neu scort) — Feedback-Anfragen sind kostenpflichtig und laufen laut
  bestehendem Kommentar in `requestFeedback()` bewusst nur auf Nutzer-Tap, nie
  automatisch; das gilt für einen Provider-Wechsel genauso.
- `Future<void> loadPersistedFeedbackProvider()`: gleiches Muster wie
  `loadPersistedTolerancePreset()`, aus `main.dart`s `create:`-Callback
  aufgerufen (fire-and-forget, nicht im Konstruktor).
- `requestFeedback()`: reicht `feedbackProvider` an `feedbackApi.requestFeedback(...)`
  durch.

`FeedbackApi.requestFeedback(scoreJson, provider)`: neuer Parameter, sendet
`provider.apiValue` als zusätzliches `"provider"`-Feld im JSON-Body.

`home_screen.dart`: `FeedbackProviderControl` direkt über `FeedbackSection` unter der
"5. Feedback"-Überschrift (gleiche Positionierung wie `TolerancePresetControl` über
`ScoreSummaryView` unter "4. Bewertung"):

```dart
Text('5. Feedback', style: Theme.of(context).textTheme.titleMedium),
const SizedBox(height: 8),
FeedbackProviderControl(
  value: session.feedbackProvider,
  onChanged: (provider) => session.setFeedbackProvider(provider),
),
FeedbackSection(session: session),
```

### Fehlerverhalten (bewusste Entscheidung)

Kein automatischer Fallback von Cloudflare auf Anthropic bei einem Fehler — gleiches
Fehlerbild wie heute (`FeedbackUnavailableError` → 503 → "Feedback fehlgeschlagen"
in der App). Der Nutzer wechselt bei Bedarf manuell über den neuen Selector zurück.
Konsistent mit der bewussten Entscheidung beim Toleranz-Preset, keine impliziten
Zusatzlogiken einzubauen.

## Testing

- Backend: `tests/test_feedback.py` bekommt einen neuen `_FakeCloudflareClient`
  (analog `_FakeMessagesClient`), der ein `create(...)` mit
  OpenAI-Tool-Call-Response-Form liefert. Tests: `cloudflare_client.py`s
  `request_feedback_points` extrahiert Punkte aus `tool_calls[0].function.arguments`
  (inkl. `json.loads()`); nutzt denselben `_normalize_points()` (ein Test mit
  string-kodiertem `arguments`-Feld genügt als Stichprobe, die Normalizer-Logik
  selbst ist schon vollständig getestet); `generate_feedback(score, provider="cloudflare")`
  ruft den Cloudflare- statt den Anthropic-Pfad auf; fehlender
  `CLOUDFLARE_ACCOUNT_ID`/`CLOUDFLARE_API_TOKEN` löst `FeedbackUnavailableError` aus;
  unbekannter `provider`-String löst ebenfalls `FeedbackUnavailableError` aus (kein
  Fallback auf Anthropic).
- Mobile: `FeedbackProvider.fromApiValue`-Roundtrip; `SessionState`-Test, dass
  `setFeedbackProvider()` **kein** automatisches `requestFeedback()` auslöst (Negativtest,
  wichtig wegen der bewussten Abweichung vom Toleranz-Preset-Verhalten); Persistenz-
  Roundtrip (gleiches Muster wie beim Toleranz-Preset); Widget-Test für
  `FeedbackProviderControl` (zwei Labels sichtbar, Tippen ruft `onChanged` mit dem
  richtigen Enum-Wert auf).

## Out of Scope (bewusst nicht Teil dieser Spec)

- Kein automatischer Fallback zwischen den Providern bei Fehlern.
- Kein drittes/viertes Provider (z. B. OpenAI direkt) — nur Anthropic + Cloudflare.
- Kein Modell-Auswahl-UI für Cloudflare — `@cf/qwen/qwen3-30b-a3b-fp8` ist fest
  hinterlegt, kein Nutzer-wählbares Untermenü.
- Keine serverseitige Persistenz/Analytics, welcher Provider wie oft gewählt wird.
- Server-seitiges Konfigurations-only-Setup (Env-Var ohne UI) war die ursprünglich
  erwogene Alternative, mit dem Nutzer aber zugunsten der In-App-Auswahl verworfen.

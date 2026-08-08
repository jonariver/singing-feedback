# Design: Pausen/Atemstellen-Erkennung (Phase 4-Rest, Teil 3)

**Datum:** 2026-08-08
**Status:** Genehmigt, bereit für Plan

## Kontext

`PLAN.md`s Phase 4 nennt acht Bewertungskategorien; das Kernpaket
(`docs/superpowers/specs/2026-08-06-scoring-engine-design.md`) deckt vier davon ab
(Cent-Abweichung, verfehlte Noten, Timing, Stabilität/Phrasenend-Drift). Glides
(`docs/superpowers/specs/2026-08-07-glide-detection-design.md`) und Stimmumfang
(`docs/superpowers/specs/2026-08-07-vocal-range-design.md`) sind bereits umgesetzt. Diese
Spec deckt den dritten und letzten Teil von Phase 4-Rest ab: Pausen/Atemstellen.

Anders als bei Glides gibt es hier **keinen** vorbereiteten Katalog-Stub und **keinen**
"noch nicht implementiert"-Kommentar in `_CATEGORY_MATCHERS` — `backend/exercises/catalog.yaml`
enthält bislang keinen Pausen-/Atem-bezogenen Eintrag. Diese Spec beginnt bei null: neue
Erkennungslogik, neuer Katalog-Eintrag, neue Konstanten, neue Wiring-Schritte.

**Scope-Entscheidung (mit dem Nutzer geklärt):** Es wird ausschließlich erkannt, wenn der
Sänger **mitten in einer gehaltenen Zielnote** eine (Atem-)Pause macht, obwohl die
Zielmelodie dort keine Pause vorsieht — die Note wird unterbrochen statt durchgehalten.
Das umgekehrte Muster (Zielmelodie hat eine Pause zwischen zwei Phrasen, aber der Sänger
atmet dort nicht) ist bewusst nicht Teil dieser Runde (siehe "Out of Scope").

Die Rohdaten sind bereits vorhanden: jeder `sung_curve`-Frame hat ein `voiced: bool`-Feld
aus pYIN (`backend/pitch_detection/pyin.py`), dessen Docstring "Pausen, Atmen, Konsonanten"
als Grund für `hz is None` explizit nennt — nur die Aggregation zu zusammenhängenden
Pausen-Läufen innerhalb einer Note fehlt bisher.

## Architektur

### Erkennung (`backend/scoring/pauses.py`, neues Modul)

```python
def compute_pause(note: dict, attributed_frames: list[dict]) -> dict:
    ...
```

Nur für gehaltene Noten anwendbar (`is_held_note()`-Gate aus `stability.py`, wieder-
verwendet, nicht dupliziert) — bei kurzen Noten ist eine "Pause mittendrin" kaum sinnvoll
von normalem Rauschen unterscheidbar, gleiches Argument wie bei Stabilität/Drift.

Betrachtetes Fenster: `[note.start_t + STABILITY_ONSET_TRIM_SECONDS, note.end_t)` — der
kurze Konsonanten-Anlauf einer Note wird ausgeschlossen, damit ein normaler Wortanlaut
(z. B. "T", "K") nicht fälschlich als Pause zählt. Gleiches Trim-Fenster wie
`stability.py`/`compute_stability`, nicht neu erfunden.

`attributed_frames` (via `attribute_sung_frames`, das **alle** Frames im Notenfenster
liefert, nicht nur stimmhafte) wird nach `aligned_t` sortiert im obigen Fenster
durchlaufen. Gesucht wird der längste zusammenhängende Lauf von Frames mit
`voiced=False` bzw. `hz is None`. Seine Dauer (letzter Frame-Zeitpunkt minus erster
Frame-Zeitpunkt im Lauf, plus eine Frame-Schrittweite) ist `gap_seconds`.

Ein Pausen-Flag liegt vor, wenn `gap_seconds > PAUSE_MIN_GAP_SECONDS`.

Rückgabeform:
```json
{"applicable": true, "gap_seconds": 0.34, "flag": true}
```

`applicable=False` (mit `gap_seconds=null`, `flag=false`), wenn die Note nicht gehalten
ist oder im betrachteten Fenster keine Frames liegen.

**Kein neuer Helfer nötig** — `is_held_note`, `attribute_sung_frames` und
`STABILITY_ONSET_TRIM_SECONDS` existieren bereits und werden 1:1 wiederverwendet, keine
Duplizierung.

### Neue Konstante (`backend/config.py`)

```python
PAUSE_MIN_GAP_SECONDS = 0.25
```

Feste Mindestdauer (nicht relativ zur Notendauer, analog `GLIDE_HEAD_SECONDS`) — einfach
zu kalibrieren, unabhängig von kurzen/langen gehaltenen Noten. Begründeter Startwert,
iterativ anpassbar, kein harter Testwert.

### Integration in `score.py`

**Gating:** `compute_pause()` wird nur aufgerufen, wenn die Note **nicht** `missed` ist.
Eine komplett verfehlte Note hat typischerweise eine riesige unstimmhafte Lücke im
zugeordneten Fenster — das ist aber kein "Pausen"-Problem, sondern schlicht eine nicht
gesungene Note, und soll nicht doppelt als Pause geflaggt werden. Anders als bei Glide
spielt die Timing-Klassifikation hier keine Rolle: Glides prüfen den Notenanfang, wo
DTW-Zeitverzerrung die ausgerichtete Kurve verschmieren kann; Pausen prüfen den
Notenkörper (nach dem Onset-Trim), wo dieser Effekt laut den Erkenntnissen aus der
Glide-Implementierung nicht relevant ist.

- Neues Notenfeld: `"pause": {...}` (Form oben).
- Neue Summary-Zahl: `"pause_flagged_count"`.
- `problem_tags` bekommt `"unerwartete_pause_in_gehaltener_note"` (neue Konstante
  `_PROBLEM_TAG_PAUSE`), wenn mindestens eine Note geflaggt ist.
- `overall_score`-Penalty: `+ pause_flagged * 10` (gleiches Gewicht wie Stabilität/Drift/Glide,
  in der bestehenden `penalty = ...`-Formel).

### Neuer Katalog-Eintrag (`backend/exercises/catalog.yaml`)

```yaml
- id: unerwartete_pause_in_gehaltener_note
  problem: Unerwartete Pause/Atemholen mitten in einer gehaltenen Note
  technik: Atemplanung vor der Phrase statt spontan mitten im Ton
  uebung: Phrase vorher markieren, wo Luft geholt wird, und gezielt nur dort atmen
```

### Phase-6-Anschluss (`backend/feedback/generate.py`, `backend/feedback/prompt.py`)

- `generate.py`: neue `_matches_pause(note) -> bool` (`return note["pause_flag"]`),
  Eintrag `"unerwartete_pause_in_gehaltener_note": _matches_pause` in
  `_CATEGORY_MATCHERS`.
- `prompt.py::build_prompt_context()`: `is_flagged`-Bedingung bekommt
  `or note["pause"]["flag"]`; die extrahierten Notenfelder bekommen `"pause_flag"` und
  `"pause_gap_seconds"` (Namensgebung passend zu `note["pause_flag"]`, das
  `_matches_pause` oben liest).
- `prompt.py::build_prompt_text()`: neue Summary-Zeile
  `f"- Pause mitten in gehaltener Note: {summary['pause_flagged_count']} Noten"`
  (gleiche Stelle wie die Stabilitäts-/Drift-/Glide-Zeilen), neuer `parts`-Eintrag pro
  auffälliger Note: `f"Pause mitten in der Note ({note['pause_gap_seconds']:.2f}s)"`.

## Mobile (`mobile/`)

- `mobile/lib/models/score_result.dart`: `ScoreNote` bekommt `pauseApplicable: bool`,
  `pauseGapSeconds: double?`, `pauseFlag: bool` — gleiches `fromJson`/`toJson`-Muster wie
  die bestehenden `glide*`-Felder. `ScoreSummary` bekommt `pauseFlaggedCount: int`.
- `mobile/lib/widgets/score_summary_view.dart`: neuer `parts`-Eintrag, wenn
  `note.pauseFlag` (Text z. B. `"Pause mitten in der Note (0.34s)"`).

## Testing

- `tests/test_scoring.py`: neue Tests für `compute_pause` — echte Pause (langer
  unstimmhafter Lauf im Notenkörper, über Schwelle) → `flag=True` + korrekte
  `gap_seconds`; kurze Lücke unter `PAUSE_MIN_GAP_SECONDS` → `flag=False`; nicht gehaltene
  Note → `applicable=False`; keine Frames im betrachteten Fenster → `applicable=False`.
- `tests/test_scoring.py::score_performance`-Tests: ein Szenario mit einer `missed`-Note,
  die rechnerisch eine große Lücke hätte — bestätigt, dass das Gating `compute_pause()`
  in diesem Fall gar nicht erst aufruft (`applicable=False`, kein Fehleintrag in
  `problem_tags`).
- `tests/test_feedback.py`: `_matches_pause` matched korrekt, `build_prompt_context`/
  `build_prompt_text` nehmen eine pausierte Note korrekt auf.
- Mobile: `mobile/test/score_result_test.dart` (falls vorhanden) bzw. neue Tests für
  `ScoreNote.fromJson`/`toJson` mit Pause-Feldern; `ScoreSummaryView`-Text für eine
  pausierte Note.
- Kein neues E2E-Fixture — gleiche Begründung wie bei Glide: die bestehende
  5-Noten-Fixture bleibt unangetastet, ein Pausen-Szenario wird über direkt
  konstruierte Frame-Dicts getestet (gleiches Muster wie die bestehenden
  Stabilitäts-/Drift-/Glide-Tests in `tests/test_scoring.py`).

### Bekannte Einschraenkung (aus dem finalen Whole-Branch-Review, nicht blockierend)

`notes.py`s `segment_target_notes()` ueberbrueckt kurze unstimmhafte Luecken in der
Zielkurve (bis zu `NOTE_SEGMENT_MAX_BRIDGE_GAP_FRAMES`, aktuell 150ms bei 100Hz) zu einer
einzigen Note - eine echte kurze Pause in der Zielmelodie kann so innerhalb einer von
`compute_pause()` als durchgehend gehaltenen Note landen. Da `PAUSE_MIN_GAP_SECONDS`=0,25s
nur 100ms ueber dieser Bruecken-Schwelle liegt, hat ein Saenger, der an genau so einer
legitimen kurzen Zielpause atmet, nur ~100ms Puffer, bevor er faelschlich als
"unerwartete Pause" geflaggt wird. Wird hier bewusst nicht behoben (dafuer muesste
`compute_pause()` Zielkurven-Stimmhaftigkeit kennen - eine Schnittstellenaenderung, die
auch `score.py`s Aufrufstelle betrifft); falls `PAUSE_MIN_GAP_SECONDS` jemals nach unten
kalibriert wird, muss es deutlich ueber `NOTE_SEGMENT_MAX_BRIDGE_GAP_FRAMES /
frame_rate_hz` bleiben, sonst verschaerft sich diese Klasse von Fehlalarmen.

## Out of Scope (bewusst nicht Teil dieser Spec)

- Fehlende Atempausen an Zielstellen: die Zielmelodie hat eine Pause zwischen zwei
  Phrasen, aber der Sänger singt durch, ohne dort Luft zu holen. Mit dem Nutzer
  während des Brainstormings bewusst aus dieser Runde ausgeklammert — eigene,
  spätere Spec/Plan-Runde, falls gewünscht.
- Jegliche Chart-Visualisierung der Pause (kein neuer Farbzustand in `PitchChart`,
  gleiche Begründung wie bei Glide: die bestehende Kurvenfärbung basiert auf
  `cents_deviation.classification`).
- Keine Änderung an `is_missed`/`classify_cents`/Timing-Logik — Pausen-Erkennung ist
  rein additiv und gated auf bereits getroffene, nicht verfehlte Noten.

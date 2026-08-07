# Design: Glide-Erkennung (Phase 4-Rest, Teil 1)

**Datum:** 2026-08-07
**Status:** Genehmigt, bereit für Plan

## Kontext

`PLAN.md`s Phase 4 nennt acht Bewertungskategorien; das Kernpaket
(`docs/superpowers/specs/2026-08-06-scoring-engine-design.md`) deckt vier davon ab
(Cent-Abweichung, verfehlte Noten, Timing, Stabilität/Phrasenend-Drift) und stellt drei
bewusst zurück: **Glides**, Stimmumfang, Pausen/Atemstellen — diese sind fachlich
unabhängig genug, um als drei separate Spec→Plan→Implementierungs-Runden behandelt zu
werden (siehe PLAN.md). Diese Spec deckt nur Glides ab.

`backend/exercises/catalog.yaml` enthält bereits einen Eintrag `haeufiges_hineingleiten`
("Auffälliges Hineingleiten/Schleifen in den Zielton statt direktem Treffen"). Er wird
seit dem Kernpaket referenziert, aber nie erzeugt: `score.py`s Kommentar sagt explizit,
dass dieser Tag nie in `problem_tags` auftaucht, und `backend/feedback/generate.py`s
`_CATEGORY_MATCHERS`-Dict hat für ihn absichtlich **keinen** Matcher-Eintrag, mit einem
Kommentar, der genau diese Lücke dokumentiert. Diese Spec schließt die Lücke.

## Architektur

### Erkennung (`backend/scoring/glides.py`, neues Modul)

Jede Note wird zeitlich in zwei Fenster geteilt:

- **Kopf-Fenster**: `[start_t, start_t + GLIDE_HEAD_SECONDS)`
- **Rest**: `[start_t + GLIDE_HEAD_SECONDS, end_t)`

Pro Fenster wird die Cent-Abweichung der zugeordneten, stimmhaften Frames (per
`aligned_t`, wie bei Stabilität/Drift) über den **Median** verdichtet — robust gegen
einzelne pYIN-Ausreißer, gleiches Prinzip wie `stability.py`.

```python
def compute_glide(note: dict, attributed_frames: list[dict]) -> dict:
    ...
```

Ein Glide liegt vor, wenn:
1. Der Kopf-Median mehr als `GLIDE_ONSET_THRESHOLD_CENTS` vom Zielton entfernt ist
   (deutlich abseits — kein normales Pitch-Rauschen), **und**
2. Der Rest-Median innerhalb von `CENTS_GREEN_THRESHOLD` liegt (die Note wurde am Ende
   sauber getroffen — sonst ist es kein "Reingleiten und Landen", sondern schlicht eine
   verfehlte Note, siehe Anwendbarkeits-Gating unten).

`direction` ist `"up"` (Kopf-Median negativ → von unten reingerutscht) oder `"down"`
(Kopf-Median positiv → von oben), `null` wenn `flag=False`. Gleiche Feldform wie
`phrase_end_drift`s `direction`.

Rückgabeform:

```json
{"applicable": true, "onset_cents_deviation": 62.3, "flag": true, "direction": "up"}
```

`applicable=False` (mit `onset_cents_deviation=null`, `flag=false`, `direction=null`),
wenn im Kopf-Fenster weniger als `GLIDE_MIN_HEAD_FRAMES` stimmhafte Frames liegen, oder
das Rest-Fenster leer ist (z. B. eine Note kürzer als `GLIDE_HEAD_SECONDS`).

**Anders als Stabilität/Drift nicht auf gehaltene Noten (`HELD_NOTE_MIN_DURATION_SECONDS`,
0,6s) beschränkt** — ein Glide beim Einsatz ist unabhängig von der Notendauer relevant.
`applicable` hängt stattdessen nur von der Frame-Verfügbarkeit im Kopf-Fenster ab.

**Kleine Voraussetzung:** `_cents_series()` (aktuell privat in `stability.py`, wandelt
zugeordnete Frames in eine nach Zeit sortierte `(aligned_t, cents_deviation)`-Liste um)
wird nach `backend/scoring/notes.py` verschoben (als `cents_series`, ohne führenden
Unterstrich) und von `stability.py` und `glides.py` gemeinsam genutzt — vermeidet
Duplizierung derselben Umrechnung in zwei Modulen.

### Neue Konstanten (`backend/config.py`)

```python
GLIDE_HEAD_SECONDS = 0.15
GLIDE_MIN_HEAD_FRAMES = 3
GLIDE_ONSET_THRESHOLD_CENTS = 60.0
```

(`CENTS_GREEN_THRESHOLD` existiert bereits und wird für das Rest-Fenster-Kriterium
wiederverwendet.) Wie die bestehenden Cent-/Timing-Schwellenwerte sind das begründete
Startwerte, iterativ anpassbar, keine harten Testwerte.

### Integration in `score.py`

**Gating:** `compute_glide()` wird nur aufgerufen, wenn die Note **nicht** `missed` ist,
ihre `cents_deviation.classification` grün oder gelb ist, **und** ihre
`timing.classification` `"on_time"` ist. Sonst wird direkt der `applicable=False`-Default
gesetzt, ohne `compute_glide()` aufzurufen.

**Nachtrag (während der Implementierung entdeckt, Entscheidung mit dem Nutzer
abgestimmt):** Die dritte Bedingung (`timing_classification == "on_time"`) war in der
ursprünglichen Fassung dieser Spec nicht vorgesehen — die Design-Annahme war, dass
Timing (wann) und Tonhöhe (Glide) unabhängige Achsen sind. Der Implementierungs-Plan
für Task 2 zeigte einen realen Interaktionseffekt: Bei einer Note mit signifikanter
Einsatz-Timing-Korrektur (z. B. 150ms zu früh gesungen) verschmiert `align_curves()`s
DTW-Zeitverzerrung die ausgerichtete Tonhöhenkurve am Notenübergang zu einer echten
Rampe (in einem beobachteten Fall: -220 bis 0 Cent innerhalb von ~150ms) — das trifft
den Glide-Schwellenwert, obwohl der Sänger keinen echten Glide gesungen hat, sondern
schlicht zu früh eingesetzt hat. Eine Note, die eine DTW-Zeitkorrektur brauchte, ist
also gerade die Art Note, deren ausgerichtete Kopf-Frames am unzuverlässigsten sind.
Die Timing-Bedingung schließt genau diesen Fall aus, ohne die Kernlogik in
`glides.py`/die Schwellenwerte anzufassen.

**Bekannte Restunschärfe (aus dem finalen Whole-Branch-Review, nicht blockierend):** Das
Kopf-Fenster (`GLIDE_HEAD_SECONDS`, 150ms) überschneidet sich teilweise mit den ersten
`STABILITY_ONSET_TRIM_SECONDS` (50ms) einer Note, die jede andere Metrik (Cent-Klassifikation,
Stabilität) bewusst als unzuverlässig verwirft. Die Timing-Bedingung reduziert das
DTW-Verschmierungsrisiko an Notenübergängen, eliminiert es aber nicht vollständig — eine
Note kann mit nur 55ms Timing-Abweichung noch als `"on_time"` gelten (Schwelle
`TIMING_OK_THRESHOLD_MS`=60ms) und trotzdem eine gewisse DTW-Verschmierung im Kopf-Fenster
tragen. Vor Vertrauen in die Funktion sollte sie an einer echten Aufnahme validiert werden;
falls sich Fehlalarme zeigen, ist ein Verschieben des Kopf-Fenster-Starts um
`STABILITY_ONSET_TRIM_SECONDS` der kleinere Hebel gegenüber einer Anhebung von
`GLIDE_ONSET_THRESHOLD_CENTS`.

- Neues Notenfeld: `"glide": {...}` (Form oben).
- Neue Summary-Zahl: `"glide_flagged_count"`.
- `problem_tags` bekommt `"haeufiges_hineingleiten"` (neue Konstante
  `_PROBLEM_TAG_GLIDE`), wenn mindestens eine Note geflaggt ist.
- `overall_score`-Penalty: `+ glide_flagged * 10` (gleiches Gewicht wie Stabilität/Drift,
  in der bestehenden `penalty = ...`-Formel).

### Phase-6-Anschluss (`backend/feedback/generate.py`, `backend/feedback/prompt.py`)

- `generate.py`: neue `_matches_glide(note) -> bool` (`return note["glide_flag"]`),
  Eintrag `"haeufiges_hineingleiten": _matches_glide` in `_CATEGORY_MATCHERS`. Der
  Kommentar, der die bisherige Lücke erklärt, wird entsprechend korrigiert/entfernt.
- `prompt.py::build_prompt_context()`: `is_flagged`-Bedingung bekommt
  `or note["glide"]["flag"]`; die extrahierten Notenfelder bekommen `"glide_flag"` und
  `"glide_direction"` (Namensgebung passend zu `note["glide_flag"]`, das
  `_matches_glide` oben liest).
- `prompt.py::build_prompt_text()`: neue Summary-Zeile
  `f"- Hineingleiten in den Zielton: {summary['glide_flagged_count']} Noten"`
  (gleiche Stelle wie die Stabilitäts-/Drift-Zeilen), neuer `parts`-Eintrag pro
  auffälliger Note: `f"rutscht rein ({note['glide_direction']})"`.

## Mobile (`mobile/`)

- `mobile/lib/models/score_result.dart`: `ScoreNote` bekommt `glideApplicable: bool`,
  `glideOnsetCentsDeviation: double?`, `glideFlag: bool`, `glideDirection: String?` —
  gleiches `fromJson`/`toJson`-Muster wie die bestehenden `drift*`-Felder.
  `ScoreSummary` bekommt `glideFlaggedCount: int`.
- `mobile/lib/widgets/score_summary_view.dart`: neuer `parts`-Eintrag, wenn
  `note.glideFlag` (Text z. B. `"gerutscht (von unten)"` bei `direction == 'up'`,
  `"gerutscht (von oben)"` bei `'down'` — gleiche Übersetzungslogik wie die bestehende
  Drift-Richtung, die `'up'`/`'down'` bereits ins Deutsche übersetzt).

## Testing

- `tests/test_scoring.py`: neue Tests für `compute_glide` — echter Glide (Kopf weit
  abseits, Rest sauber) → `flag=True` + korrekte `direction`; sauberer Einsatz (Kopf
  schon nah am Ziel) → `flag=False`; zu wenige Kopf-Frames → `applicable=False`; Note
  kürzer als `GLIDE_HEAD_SECONDS` (kein Rest-Fenster) → `applicable=False`.
- `tests/test_scoring.py::score_performance`-Tests: ein Szenario, bei dem eine Note
  `missed`/rot ist UND rein rechnerisch einen "Glide-artigen" Kopf hätte — bestätigt,
  dass das Gating in `score.py` `compute_glide()` in diesem Fall gar nicht erst aufruft
  (`applicable=False`, kein Fehleintrag in `problem_tags`).
- `tests/test_feedback.py` (falls vorhanden, sonst neuer Test dort): `_matches_glide`
  matched korrekt, `build_prompt_context`/`build_prompt_text` nehmen eine geglittene
  Note korrekt auf.
- Mobile: `mobile/test/score_result_test.dart` (falls vorhanden) bzw. neue Tests für
  `ScoreNote.fromJson`/`toJson` mit Glide-Feldern; `ScoreSummaryView`-Text für eine
  geglittene Note.
- Kein neues E2E-Fixture — die bestehende 5-Noten-Fixture
  (`tests/fixtures/generate_fixtures.py`) bleibt unangetastet, um bestehende Annahmen in
  anderen Tests (Notenzahl, Timing) nicht zu stören. Ein Glide-Szenario wird stattdessen
  über direkt konstruierte Frame-Dicts getestet (gleiches Muster wie die bestehenden
  Stabilitäts-/Drift-Tests in `tests/test_scoring.py`).

## Out of Scope (bewusst nicht Teil dieser Spec)

- Stimmumfang der Aufnahme, Pausen/Atemstellen (restliche PLAN.md-Phase-4-Kategorien) —
  eigene, spätere Spec/Plan-Runden.
- Grün/Gelb/Rot-Einfärbung der Kurve selbst für Glide-Abschnitte im Chart — die
  bestehende Kurvenfärbung (Phase 5) basiert auf `cents_deviation.classification`, nicht
  auf einem neuen Glide-spezifischen Farbzustand; ein visuelles Glide-Overlay im Chart
  wäre eine eigene, spätere Erweiterung.
- Keine Änderung an `is_missed`/`classify_cents`/Timing-Logik — Glide ist rein additiv
  und gated auf bereits getroffene, nicht verfehlte Noten.

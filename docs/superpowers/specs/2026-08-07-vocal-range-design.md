# Design: Stimmumfang der Aufnahme (Phase 4-Rest, Teil 2)

**Datum:** 2026-08-07
**Status:** Genehmigt, bereit für Plan

## Kontext

`PLAN.md`s Phase 4 nennt acht Bewertungskategorien; das Kernpaket deckt vier ab, Glides
(Teil 1, `docs/superpowers/specs/2026-08-07-glide-detection-design.md`) einen fünften.
Diese Spec deckt den sechsten ab: den Tonhöhenumfang der gesungenen Aufnahme selbst
(nicht der Zielmelodie).

**Architektonisch anders als jede bisherige Metrik**: Stimmumfang braucht weder
Noten-Segmentierung noch DTW-Ausrichtung — er ist eine reine Aggregation über die
gesungenen `hz`/`voiced`-Werte der ganzen Aufnahme. Die Zeitausrichtung (`aligned_t`)
ändert `hz`-Werte nicht, nur ihre Zeitposition; `compute_vocal_range()` arbeitet direkt
auf `sung_curve` und ignoriert `aligned_t` komplett.

**Bewusst rein informativ** (mit Nutzer geklärt): kein Problem-Tag, kein neuer
Übungskatalog-Eintrag, keine Ampel-Bewertung. Der natürliche Stimmumfang eines Sängers
ist keine "behebbare" Kategorie wie Timing oder Stabilität — er wird nur berichtet, nicht
bewertet. `overall_score` bleibt unverändert.

## Architektur

### Berechnung (`backend/scoring/vocal_range.py`, neues Modul)

```python
def compute_vocal_range(sung_curve: list[dict]) -> dict:
    ...
```

Filtert stimmhafte Frames (`frame.get("voiced") and frame.get("hz") is not None`),
sortiert ihre `hz`-Werte. Bei weniger als `VOCAL_RANGE_MIN_VOICED_FRAMES` stimmhaften
Frames (z. B. eine stille/leere Aufnahme): `applicable=False`.

Sonst: statt echtem Minimum/Maximum wird bei `VOCAL_RANGE_LOW_PERCENTILE`/
`VOCAL_RANGE_HIGH_PERCENTILE` (5./95. Perzentil) abgeschnitten — ein einzelner
pYIN-Ausreißer (Oktavsprung, Fehlerkennung von Rauschen als Ton) verzerrt den
angezeigten Umfang dann nicht um eine Oktave. Perzentil-Index ohne Interpolation
(`round(percentile/100 * (n-1))`), gleicher Stil wie die Median-Berechnungen in
`stability.py`/`pitch.py` (kein `numpy`, reine sortierte Listen).

`confidence` (von pYIN, auf jedem Frame vorhanden) wird bewusst **nicht** als
zusätzlicher Filter genutzt — kein anderer Teil der Bewertungs-Engine tut das, keinen
neuen Präzedenzfall für dieses eine Modul schaffen.

Rückgabeform:

```json
{"applicable": true, "min_hz": 196.5, "max_hz": 587.3, "min_midi_note": 55, "max_midi_note": 74}
```

`applicable=False` → alle vier Werte `null`.

**Kleine Voraussetzung:** Die MIDI-Notennummer-Umrechnung (`round(69 + 12 *
log2(hz/440))`), bisher inline in `notes.py::segment_target_notes()` dupliziert, wird
als `hz_to_midi_note(hz: float) -> int` in `backend/scoring/notes.py` extrahiert und von
beiden Stellen genutzt — vermeidet, dieselbe Formel ein zweites Mal zu schreiben (gleiches
Prinzip wie die `cents_series`-Extraktion bei Glides).

### Neue Konstanten (`backend/config.py`)

```python
VOCAL_RANGE_LOW_PERCENTILE = 5.0
VOCAL_RANGE_HIGH_PERCENTILE = 95.0
VOCAL_RANGE_MIN_VOICED_FRAMES = 10
```

Wie alle bisherigen Schwellenwerte: begründete Startwerte, iterativ anpassbar.

### Integration in `score.py`

Ein einziger Aufruf `compute_vocal_range(sung_curve)` zu Beginn von
`score_performance()` (unabhängig von der Noten-Schleife), Ergebnis direkt als neues
`summary["vocal_range"]`-Feld. Keine Interaktion mit `problem_tags`, `overall_score`,
oder irgendeinem Notenfeld.

## Mobile (`mobile/`)

- `mobile/lib/models/score_result.dart`: neue Klasse `VocalRange` (`applicable: bool`,
  `minHz: double?`, `maxHz: double?`, `minMidiNote: int?`, `maxMidiNote: int?`,
  `fromJson`/`toJson`, gleiches Muster wie `ScoreSummary`). `ScoreSummary` bekommt ein
  Feld `vocalRange: VocalRange`.
- `mobile/lib/widgets/score_summary_view.dart`: neue Zeile, z. B.
  `"Stimmumfang: G3–D5"`, nur wenn `vocalRange.applicable`. Notennamen werden
  **mobile-seitig** aus `minMidiNote`/`maxMidiNote` berechnet — eine neue reine Funktion
  `String midiNoteName(int midiNote)` (Standardformel: Notenname-Array + Oktave =
  `midiNote ~/ 12 - 1`), unabhängig testbar, gleiches Muster wie `trackScoreColor`. Das
  Scoring-Modul bleibt bewusst frei von einer `pretty_midi`-Abhängigkeit (funktioniert
  auch im Referenzaufnahme-Modus ohne MIDI-Datei).

## Testing

- `tests/test_scoring.py`: `compute_vocal_range` — normale Aufnahme mit ein paar
  Ausreißer-Frames weit außerhalb des eigentlichen Umfangs (Perzentil-Trimmung schneidet
  sie ab, `min_hz`/`max_hz` entsprechen dem Bereich der übrigen Frames); zu wenige
  stimmhafte Frames → `applicable=False`; komplett unstimmhafte Aufnahme →
  `applicable=False`; einheitliche Tonhöhe (alle Frames identisch) → `min_hz == max_hz`,
  kein Absturz. `hz_to_midi_note`-Extraktion: bestehender
  `test_track_pitch_curve_matches_expected_notes`-artiger Test in `test_scoring.py`
  bestätigt, dass die extrahierte Funktion dieselben Werte wie vorher liefert (Regression
  auf die bestehende `segment_target_notes`-Nutzung).
- `tests/test_scoring.py::score_performance`-Test: `summary["vocal_range"]` wird korrekt
  durchgereicht (z. B. anhand der bestehenden 5-Noten-Fixture-artigen synthetischen
  Kurve).
- Mobile: `midiNoteName`-Funktion (Grenzfälle: C4=60, A4=69, Oktavgrenzen), `VocalRange`
  round-trip (`fromJson`/`toJson`), `ScoreSummaryView`-Textzeile für `applicable=true` und
  `applicable=false` (keine Zeile).

## Out of Scope (bewusst nicht Teil dieser Spec)

- Pausen/Atemstellen (letzter verbleibender PLAN.md-Phase-4-Punkt) — eigene, spätere
  Spec/Plan-Runde.
- Kein Vergleich gegen den Tonumfang der Zielmelodie (kein Problem-Tag, keine
  Bewertung) — bewusste Entscheidung, siehe Kontext oben.
- Keine Änderung an bestehenden Metriken (Cent-Abweichung, Timing, Stabilität, Drift,
  Glide) — rein additiv.

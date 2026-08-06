# Bewertungs-Engine: Kernpaket (Cent-Abweichung, verfehlte Noten, Timing, Stabilität/Drift)

Status: Design abgestimmt am 2026-08-06, bereit für Implementierungsplan.

## Kontext

Seit Phase 3 wird die gesungene Kurve per DTW auf die Zielmelodie ausgerichtet
(`aligned_t`-Feld pro Frame), aber es gibt noch keine Bewertung — nur die visuelle
Gegenüberstellung im Chart. `PLAN.md`s Phase 4 ("Bewertungs-Engine") sieht acht
Mess-Kategorien vor: Cent-Abweichung, verfehlte Zielnoten, zu frühe/späte Einsätze,
Stabilität gehaltener Töne, Phrasenend-Drift, Glides, Stimmumfang, Pausen/Atemstellen.
`backend/scoring/` ist bisher ein leerer Stub.

**Scope-Entscheidungen (mit Nutzer geklärt):**
- **Kernpaket** dieser Runde: Cent-Abweichung pro Note, verfehlte Zielnoten, Timing
  (früh/spät), Stabilität/Phrasenend-Drift bei gehaltenen Tönen. Explizit **nicht**
  Teil dieser Runde: Glides, Stimmumfang, Pausen/Atemstellen (spätere Runde).
- Backend-JSON **plus** eine einfache Text-/Zahlen-Zusammenfassung in der Mobile-App
  (neuer Abschnitt "4. Bewertung" unter dem Chart) — explizit **nicht** die
  grün/gelb/rot-Kurvenfärbung selbst (das bleibt die separate, spätere Phase 5 und
  braucht neue CustomPainter-Infrastruktur für Segment-Färbung, die es noch nicht gibt).
- Grün/Gelb/Rot-Schwellen: ±15 Cent (grün) / ±50 Cent (gelb) / darüber rot — direkt aus
  `PLAN.md`s dokumentierter Annahme übernommen, als benannte Konstanten.
- **Noten-Erkennung ohne MIDI-Session-Kopplung**: "Noten" werden direkt aus der
  `target_curve` segmentiert (zusammenhängende Abschnitte mit stabiler Tonhöhe), nicht
  aus `pretty_midi.Note`-Objekten via `MIDI_SESSIONS`. Dadurch braucht das Scoring-Modul
  nur `target_curve`/`sung_curve` als Eingabe und funktioniert einheitlich für MIDI-Ziel
  (exakt, da die Kurve schon eine Stufenfunktion ist) und Referenzaufnahme-Ziel
  (Näherung über eine echte, verrauschte Tonhöhenkurve).

## Architektur & Datenfluss

### Noten-Segmentierung (`backend/scoring/notes.py`)

`segment_target_notes(target_curve, ...) -> list[dict]` läuft die Frames der Zielkurve
durch und gruppiert sie mit einem gleitenden Median als Toleranzband:

- Ein stimmhafter Frame gehört zum aktuellen Segment, wenn seine Cent-Abweichung vom
  gleitenden Median der letzten `NOTE_SEGMENT_ROLLING_WINDOW_FRAMES` (30 Frames/300ms)
  Frames im Segment innerhalb von `NOTE_SEGMENT_TOLERANCE_CENTS` (50 Cent) liegt —
  ein echter Notenwechsel (≥100 Cent) schneidet sofort, langsames Drift/Vibrato
  reißt das Segment nicht ab.
- Unstimmhafte/leere Frames überbrücken eine Lücke bis `NOTE_SEGMENT_MAX_BRIDGE_GAP_FRAMES`
  (15 Frames/150ms); danach wird das Segment geschlossen.
- Segmente unter `NOTE_SEGMENT_MIN_DURATION_SECONDS` (0.12s) werden verworfen
  (Rauschen bei Referenzaufnahmen, bei MIDI ein No-op).

Für die Fixture (5 MIDI-Noten, keine Pausen dazwischen, 3-4 Halbtöne Abstand) ergibt
das exakt 5 Segmente C4-E4-G4-E4-C4. Bekannte, dokumentierte Grenze: zwei direkt
aufeinanderfolgende Noten derselben Tonhöhe ohne Pause sind nicht unterscheidbar — kommt
in der Fixture nicht vor, wird als Kommentar im Modul festgehalten statt jetzt gelöst.

Ein gemeinsamer Helfer `attribute_sung_frames(sung_curve, note, is_last_note)` ordnet
jedem Zielnoten-Zeitfenster `[start_t, end_t)` die per `aligned_t` passenden
Gesangs-Frames zu (bei der letzten Note offen nach oben, damit DTW-Randeffekte keine
Frames verschlucken).

### Cent-Abweichung & verfehlte Noten (`backend/scoring/pitch.py`)

Pro Note werden die zugeordneten stimmhaften Frames per **Median** (nicht Mittelwert)
zu einer Abweichung verdichtet — das ist der Kniff, der Phrasenend-Drift (nur die
letzten 300ms betroffen) nicht in die allgemeine Cent-Bewertung durchschlagen lässt,
weil der Median vom stabilen Hauptteil dominiert wird. Klassifikation über
`CENTS_GREEN_THRESHOLD`/`CENTS_YELLOW_THRESHOLD` (15/50 Cent).

Eine Note gilt als **verfehlt**, wenn die stimmhafte Abdeckung im Zeitfenster unter
`MISSED_NOTE_MIN_COVERAGE_FRACTION` (50%) liegt (Stille/Pause statt Gesang) ODER die
mittlere Abweichung `MISSED_NOTE_CENTS_THRESHOLD` (300 Cent) übersteigt (komplett
falscher Ton trotz durchgehendem Gesang). Für die Fixture: keine der 5 Noten wird
verfehlt.

### Timing (`backend/scoring/timing.py`)

Nutzt direkt `aligned_t - t` der dem Notenanfang nächstgelegenen stimmhaften
Gesangs-Frames (Median über ein kleines Fenster) — derselbe Wert, den Phase 3s
End-to-End-Test schon für die 150ms-zu-früh-Note validiert hat. Ab
`TIMING_OK_THRESHOLD_MS` (60ms) gilt eine Note als zu früh/spät. Da die
DTW-Ausrichtung auf der Onset-Hüllkurve läuft (nicht auf Rohtonhöhe, siehe
`backend/sync/features.py`), beeinflussen Cent-Probleme anderer Noten das
Timing-Ergebnis nicht.

### Stabilität & Phrasenend-Drift (`backend/scoring/stability.py`)

Nur für gehaltene Noten (`HELD_NOTE_MIN_DURATION_SECONDS`, 0.6s) relevant. Zwei
**disjunkte** Zeitfenster statt eines gemeinsamen: der Hauptteil der Note (ohne die
letzten `DRIFT_TAIL_SECONDS`, 0.3s) misst Stabilität über die Streuung
(Median-Abweichung, `STABILITY_MAD_THRESHOLD_CENTS`); die letzten 300ms werden separat
gegen den Hauptteil-Median verglichen (`DRIFT_FLAG_THRESHOLD_CENTS`, 30 Cent) und
ergeben den Drift-Wert samt Richtung. Die Trennung in disjunkte Fenster ist der Grund,
warum eine konstant falsch gesungene Note (durchgehend -40 Cent, kein Drift) korrekt
von einer am Ende absackenden Note (stabiler Hauptteil, aber Drift im letzten Viertel)
unterschieden wird — sonst würden beide Fälle dieselbe hohe Streuung zeigen.

### Output-JSON (`backend/scoring/score.py`)

`score_performance(target_curve, sung_curve, frame_rate_hz=100.0) -> dict` ist der
Orchestrator: ruft Segmentierung + alle vier Metriken pro Note auf und liefert:

```json
{
  "notes": [
    {
      "index": 0, "start_t": 0.0, "end_t": 1.0,
      "target_hz": 261.626, "target_midi_note": 60,
      "missed": false, "coverage_fraction": 0.97,
      "cents_deviation": {"value": 1.2, "classification": "green"},
      "timing": {"deviation_ms": 4.0, "classification": "on_time"},
      "held": true,
      "stability": {"applicable": true, "mad_cents": 0.8, "flag": false},
      "phrase_end_drift": {"applicable": true, "drift_cents": 0.3, "flag": false, "direction": null}
    }
  ],
  "summary": {
    "note_count": 5, "missed_count": 0,
    "cents_green": 4, "cents_yellow": 1, "cents_red": 0,
    "timing_flagged_count": 1, "stability_flagged_count": 0,
    "phrase_end_drift_flagged_count": 1,
    "overall_score": 91.0,
    "problem_tags": ["timingprobleme", "absinkende_phrasenenden"]
  }
}
```

`problem_tags` bildet 1:1 auf die bestehenden `backend/exercises/catalog.yaml`-IDs ab
(`phrase_end_drift.flag → absinkende_phrasenenden`, `stability.flag →
instabile_lange_toene`, `missed`/rot → `unsaubere_einsaetze`, Timing-Flag →
`timingprobleme`), damit eine spätere Phase 6 ohne Übersetzungsschicht darauf aufbauen
kann. `haeufiges_hineingleiten` (Glides) taucht nie auf — bewusst nicht Teil dieser
Runde. `overall_score` ist eine dokumentiert-illustrative Kennzahl (Abzüge pro Problem,
gemittelt über alle Noten), kein harter Testwert — Tests prüfen Klassifikationen, nicht
diese exakte Zahl.

Neue Konstanten leben in `backend/config.py` neben `PITCH_FMIN_HZ` etc.

### Modul-Aufteilung

Analog zu `backend/sync` (Signalverarbeitungs-Bausteine getrennt vom Orchestrator):
`notes.py` (Segmentierung + Zuordnung), `pitch.py` (Cent-Abweichung + verfehlte Noten),
`timing.py`, `stability.py`, `score.py` (Orchestrator + JSON-Form), `__init__.py`
(Re-Export von `score_performance` und `segment_target_notes`).

### Neuer Endpoint: `POST /api/score`

Bewusst **kein** Anhängen an `/api/sync/align`, sondern ein neuer, schlanker Endpoint,
der `target_curve` + die bereits ausgerichtete `sung_curve` (mit `aligned_t`) als
JSON-Body entgegennimmt — kein erneuter Audio-Upload nötig, der Client hat beide Kurven
nach `align()` schon vorliegen. Das hält die Trennung sauber (Alignment kostet Audio-
Dekodierung + DTW, Scoring ist reine, günstige Berechnung auf schon vorhandenen Kurven)
und vermeidet, dass jeder Alignment-Aufruf zwangsläufig auch Scoring-Kosten trägt.

```python
class ScoreRequest(BaseModel):
    target_curve: list[dict]
    sung_curve: list[dict]  # muss die AUSGERICHTETE Kurve sein (aligned_t vorhanden)

@router.post("/score")
def score(request: Request, body: ScoreRequest) -> dict:
    if len(body.target_curve) > MAX_SCORE_CURVE_FRAMES or len(body.sung_curve) > MAX_SCORE_CURVE_FRAMES:
        raise HTTPException(status_code=413, detail="Kurve ist unerwartet lang.")
    try:
        result = score_performance(body.target_curve, body.sung_curve)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return {"score": result}
```

Kein `enforce_upload_rate_limit` (keine Audio-Dekodierung hier), aber eine eigene
Längenprüfung (`MAX_SCORE_CURVE_FRAMES`), da ein Client theoretisch ein überlanges
JSON-Array direkt posten könnte, ohne über `/api/audio/analyze`/`/api/sync/align`
gegangen zu sein (deren `MAX_AUDIO_SECONDS`-Deckelung hier nicht automatisch greift).

## Mobile-Client (`mobile/`)

Folgt exakt dem `align()`-Muster aus Phase 3:

- `mobile/lib/api/api_client.dart` bekommt eine neue generische `postJson()`-Methode
  (bisher nur `get`/`delete`/`postMultipart`) — die Klasse ist laut eigenem Kommentar
  bewusst für genau diese Erweiterung offen gehalten.
- Neue `mobile/lib/api/score_api.dart` (`ScoreApi`, analog zu `SyncApi`) und
  `mobile/lib/models/score_result.dart` (`fromJson`-Parsing wie bei `SungPoint`).
- `mobile/lib/state/session_state.dart`: `ScoreResult? scoreResult`,
  `LoadStatus scoreStatus`, `String scoreMessage`; `Future<void> score()` wird
  automatisch am Ende eines erfolgreichen `align()` angestoßen (kein manueller Button,
  gleiches Prinzip wie `align()` nach `analyzeAudio()`). Wird über die bestehende
  `_resetAlignment()`-Stelle mit zurückgesetzt, da eine veraltete Bewertung gegen ein
  altes Alignment genauso falsch wäre wie das veraltete Alignment selbst (siehe Finding
  aus der Phase-3-Abschlussreview).
- **Wichtiges Detail**: `score()` muss exakt die Kurve verwenden, die tatsächlich
  ausgerichtet wurde — im Referenzaufnahme-Modus ist das die unangetastete
  `referenceRawCurve`, nicht `displayedTargetCurve` (die clientseitig transponiert für
  die Anzeige ist, aber nie an `align()`/das Backend geschickt wird). `align()` legt die
  tatsächlich verwendete Zielkurve in einem eigenen Feld ab, das `score()` danach liest.
- `mobile/lib/screens/home_screen.dart`: neuer Abschnitt "4. Bewertung" nach dem
  bestehenden Chart-Abschnitt, gleiches visuelles Muster (`Divider` + Überschrift +
  `StatusBanner(status: session.scoreStatus, message: session.scoreMessage)`). Inhalt:
  eine Zeile pro Note (Ampel-Symbol + Cent-Wert, Timing-Klassifikation, ggf.
  Stabilitäts-/Drift-Hinweis) plus eine Zusammenfassungszeile (verfehlt/gelb/rot-Zähler,
  Gesamtwert). Reiner Text, keine neue Chart-Infrastruktur.

## Fehlerbehandlung

- Backend: zu lange Kurven → 413; `score_performance` wirft `ValueError`, wenn
  `sung_curve`-Frames kein `aligned_t`-Feld haben (verteidigt gegen einen Aufrufer, der
  vergessen hat, vorher `align_curves` aufzurufen) → 400 mit deutscher Meldung, folgt dem
  bestehenden Muster.
- Client: `score()`-Fehler setzen `scoreStatus = LoadStatus.error` +
  `scoreMessage`, ohne `alignedSungCurve`/Chart-Anzeige zu berühren — die
  Tonhöhen-Gegenüberstellung bleibt nutzbar, auch wenn nur die Bewertung fehlschlägt.

## Tests

- `tests/test_scoring.py` (neu): Unit-Tests je Funktion — Segmentierung
  (Toleranzband-Schnitt, Lücken-Überbrückung bis/über dem Limit,
  Mindestdauer-Filterung), Schwellenwert-Grenzfälle für `classify_cents`/
  `classify_timing`, `is_missed`-Abdeckungs-/Cent-Grenzfälle,
  `compute_stability`/`compute_phrase_end_drift` an einer kurzen (<0.6s) Note
  (`applicable=False`-Zweig, den die Fixture nicht abdeckt, da alle 5 Fixture-Noten
  "gehalten" sind).
- `tests/test_e2e_phase4.py` (neu, analog zu `test_e2e_phase3.py`): nutzt dieselbe
  Fixture, prüft konkrete Erwartungen für alle 5 Noten — u.a. Note 1 (konstant -40 Cent)
  → gelb, aber kein Drift-Flag; Note 2 (150ms zu früh) → grün, aber "too_early"; Note 3
  (Drift in den letzten 300ms) → grün (Median-Effekt), aber Drift-Flag mit Richtung
  "down"; keine Note wird als verfehlt markiert; `problem_tags` enthält genau
  `timingprobleme` und `absinkende_phrasenenden`.

## Out of Scope (bewusst nicht Teil dieses Designs)

- Glides, Stimmumfang, Pausen/Atemstellen (restliche PLAN.md-Phase-4-Kategorien) —
  spätere Runde.
- Grün/Gelb/Rot-Einfärbung der Kurve selbst im Chart (Phase 5, eigene
  CustomPainter-Infrastruktur nötig).
- Claude-generierte Feedback-Texte / Übungsauswahl (Phase 6) — `problem_tags` legt nur
  den Datenvertrag dafür an.
- Keine Kopplung an `MIDI_SESSIONS`/echte `pretty_midi.Note`-Grenzen — bewusste
  Design-Entscheidung für Uniformität zwischen MIDI- und Referenzaufnahme-Modus,
  dokumentierte Grenze bei identischen aufeinanderfolgenden Noten ohne Pause.

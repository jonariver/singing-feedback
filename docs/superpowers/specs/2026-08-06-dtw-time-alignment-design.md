# DTW-Zeitausrichtung zwischen Ziel- und Gesangskurve (Mobile-App)

Status: Design abgestimmt am 2026-08-06, bereit für Implementierungsplan.

## Kontext

Seit Phase 1 werden Ziel- und Gesangskurve nur roh auf ihrer jeweils eigenen Aufnahmezeit
nebeneinander gezeichnet (`PLAN.md`: "Phase 1 vergleicht beide Kurven noch ueber die rohe
absolute Zeitachse, ohne Ausrichtung"). Singt der Nutzer eine Phrase zu früh/spät ein oder driftet
das Timing über eine gehaltene Note, laufen beide Kurven im Chart sichtbar auseinander, obwohl die
Tonhöhe an sich passen könnte. Phase 3 des Plans sieht dafür eine DTW-Ausrichtung (Dynamic Time
Warping) vor — explizit auf einer tonhöhen-unabhängigen Rhythmus-/Energiehüllkurve (Onsets), nicht
auf der Rohtonhöhe selbst, weil ein DTW auf Rohtonhöhe genau dann versagt, wenn der Nutzer die
falsche Note singt — also exakt dem Fall, den die spätere Bewertung (Phase 4) messen soll.

**Scope-Entscheidungen (mit Nutzer geklärt):**
- Nur die Mobile-App (Flutter, `mobile/`) bekommt in dieser Runde die Chart-Anbindung. Das
  Web-Frontend (`frontend/app.js`) bleibt unverändert (hat ohnehin keinen
  Referenzaufnahme-Modus und hinkt bereits hinterher).
- Backend-Arbeit (Algorithmus + neuer Endpunkt) ist für beide Ziel-Typen (MIDI und
  Referenzaufnahme) gemeinsam nötig, da der Mobile-Client beide Modi unterstützt.
- Sobald das Alignment fertig ist, ersetzt die ausgerichtete Kurve die rohe Anzeige direkt —
  kein Umschalter roh/ausgerichtet (einfachste UX, ein Chart-Zustand weniger).
- Schlägt das Alignment fehl, bleibt die bisherige unausgerichtete Anzeige sichtbar statt eines
  Absturzes oder einer leeren Kurve.

## Architektur & Datenfluss

**Kein Caching von Audiodaten serverseitig.** Der bestehende Guardrail ("keine dauerhafte
Speicherung von Audiodateien") gilt weiter — `MIDI_SESSIONS` hält nur das geparste
`pretty_midi.PrettyMIDI`-Objekt, nie Audio-Rohbytes. Der neue Endpunkt bekommt daher die
gesungene (und ggf. Referenz-)Audiodatei in jedem Aufruf frisch mitgeschickt.

### Feature-Extraktion (neu: `backend/sync/features.py`)

DTW läuft nicht auf Rohtonhöhe, sondern auf einer Onset-/Energiehüllkurve:

- **Gesungene Seite & Referenzaufnahme-Ziel:** echte Onset-Stärke aus dem Audiosignal via
  `librosa.onset.onset_strength`, mit einer Hop-Length, die exakt auf die 100Hz-Frame-Rate der
  bestehenden Tonhöhenkurven abgestimmt ist (`hop_length = round(sr / frame_rate_hz)`) — dadurch
  entspricht Hüllkurven-Index `i` direkt Kurven-Frame `i`, ohne separaten Resampling-Schritt.
- **MIDI-Ziel:** kein Audiosignal vorhanden, und es existiert kein Synthesizer im Projekt (die in
  `PLAN.md` erwähnte "Vorschau-Synthese" wurde nie implementiert). Statt eigens einen
  Sinus-Synthesizer zu bauen, nur um ihn wieder per `onset_strength` zu analysieren, wird die
  Hüllkurve direkt aus den MIDI-Note-Startzeiten als synthetischer Impuls-Zug mit kurzem Decay
  gebaut — exakter als ein Synthese-/Analyse-Umweg, weil die Onset-Zeiten aus MIDI bereits exakt
  bekannt sind.

### DTW (neu: `backend/sync/align.py`)

`librosa.sequence.dtw` (bereits vorhandene Abhängigkeit, `librosa>=0.10.2` in
`requirements.txt`) statt einer handgerollten numpy/scipy-Implementierung. Begründung: Die alte
Notiz in `requirements.txt` zu "eigener DTW-Featurevergleich" stammt aus einer Zeit vor der
aktuellen Abhängigkeitsmenge — `librosa` ist längst Pflichtabhängigkeit und bringt eine getestete,
backtrack-fähige DTW mit. Eine eigene Implementierung (Backtracking, Tie-Breaking,
Step-Pattern-Wahl) wäre zusätzliche Fehlerfläche ohne Nutzen, sobald "keine neue Abhängigkeit"
bereits erfüllt ist. Global Alignment (`subseq=False`) ist korrekt, da Clips kurz sind (20–60s)
und die komplette Zielmelodie enthalten, kein Teil-/Streaming-Abgleich.

Die z-normalisierten Hüllkurven von Ziel und Gesang werden gegeneinander per DTW ausgerichtet;
der resultierende Warping-Pfad ordnet jedem Gesangs-Frame eine Zielzeit zu.

### Output-Vertrag

Jeder Frame der gesungenen Kurve bekommt ein zusätzliches Feld `aligned_t` (die Zeit auf der
Zielachse, auf die dieser Frame laut DTW-Pfad gemappt wurde). Bewusst **keine** Umrechnung der
gesamten Kurve auf das Ziel-Zeitraster:
- Erhält die echte Aufnahmezeit `t`, die für spätere Wiedergabe-Synchronisierung (Klick-Position
  im Chart → Position in der Audiodatei) gebraucht wird — eine resamplete Kurve würde diesen
  Bezug kappen.
- Vermeidet erfundene `hz`-Zwischenwerte über unstimmhafte Lücken, was dem bestehenden
  Zeichenverhalten (Linienabbruch bei `hz == null`/`voiced == false`) widerspräche.
- `aligned_t` ist durch den DTW-Pfad monoton nicht-fallend — Phase 4 (Bewertung) kann später
  einfach linear gegen das feste Zielraster abgleichen, ohne dass Phase 3 bereits eine
  Resampling-Politik festlegt.

### Neuer Endpunkt

`POST /api/sync/align` (neue Route im bestehenden Router, `backend/api/routes.py`):

- Eingabe: gesungene Audiodatei (Pflicht) plus **entweder** `session_id` + `track_index` +
  optional `transpose` (MIDI-Fall) **oder** eine zweite Referenz-Audiodatei
  (Referenzaufnahme-Fall). Fehlt beides oder ist die `session_id` unbekannt/abgelaufen → 400 bzw.
  404 mit deutscher Fehlermeldung, analog zu den bestehenden Routen.
- Ausgabe: `{"target_curve": [...], "sung_curve": [...mit aligned_t...], "target_duration": float}`.
  `target_curve` wird mitgeliefert, obwohl der Client sie ggf. schon über einen früheren aufruf
  hat, damit die Antwort in sich geschlossen ist und der Client keine zwei Requests anhand ihrer
  Reihenfolge korrelieren muss.
- Bekannter Kompromiss: die Tonhöhenkurve wird für Ziel und Gesang serverseitig neu berechnet,
  obwohl der Client sie in vielen Fällen schon einmal einzeln angefordert hat (z.B. beim
  MIDI-Track-Preview oder der ersten `analyzeAudio()`-Vorschau) — unvermeidbar ohne den
  No-Audio-Caching-Guardrail zu verletzen, da Audio serverseitig nirgends zwischengespeichert
  wird.

## Mobile-Client (`mobile/`)

- `mobile/lib/models/sung_point.dart`: neues Feld `final double? alignedT;`, parst
  `json['aligned_t']` (nullable).
- `mobile/lib/api/api_client.dart`: `postMultipart` wird erweitert, um mehrere Dateien und
  zusätzliche Formularfelder zu unterstützen (gebraucht für gesungene Audiodatei +
  Session-Parameter *oder* zweite Referenzdatei in einem Request). Bestehende Single-File-Nutzung
  durch `MidiApi`/`AudioApi` bleibt unverändert funktionsfähig.
- Neue Datei `mobile/lib/api/sync_api.dart`: `SyncApi.align(...)` nimmt gesungene Audiobytes plus
  (je nach `referenceSource`) entweder MIDI-Session-Parameter oder Referenz-Audiobytes entgegen —
  alle bereits als Felder in `SessionState` vorhanden, kein neues Byte-Plumbing nötig — und liefert
  die geparste `aligned_t`-tragende Gesangskurve zurück.
- `mobile/lib/state/session_state.dart`: neue Felder `List<SungPoint> alignedSungCurve = []`,
  `LoadStatus alignStatus = LoadStatus.idle`, `String alignMessage = ''`; neue Methode `align()`,
  die nach erfolgreichem `analyzeAudio()` automatisch angestoßen wird (kein manueller Button).
  Schlägt `align()` fehl, bleibt `alignedSungCurve` leer/`alignStatus == LoadStatus.error`, und
  die Chart-Anzeige fällt unten auf die rohe Kurve zurück (siehe Fehlerbehandlung).
- `mobile/lib/widgets/pitch_chart.dart` (`_PitchChartPainter`): die gesungene Serie zeichnet
  `p.alignedT ?? p.t` statt `p.t` für die x-Position, sobald `alignedSungCurve` befüllt ist —
  andernfalls (Alignment noch nicht fertig oder fehlgeschlagen) wie bisher `sungCurve` mit `t`.

## Fehlerbehandlung

- Backend: fehlende/unbekannte `session_id`, fehlende Zielangabe (weder Track noch Referenzdatei),
  nicht dekodierbares Audio → jeweils 400/404 mit deutscher Fehlermeldung, folgt dem bestehenden
  Muster aus `backend/api/routes.py` (`PitchAnalysisError` → HTTP 400 → `ApiException` im Client).
- Client: `align()`-Fehler setzt `alignStatus = LoadStatus.error` und eine deutsche
  `alignMessage`, verändert aber `sungCurve`/`targetCurve` nicht — die App zeigt weiterhin die
  unausgerichtete Kurve statt eines leeren oder abgestürzten Charts. Kein Retry-Automatismus in
  dieser Runde (YAGNI).

## Tests

- `tests/test_sync.py` (neu, Unit-Ebene): `onset_envelope_from_midi_track` (Länge stimmt mit
  `track_pitch_curve` überein, Spitzen liegen an/nahe den Note-Onset-Frames),
  `onset_envelope_from_signal` (nicht-negativ, korrekte Länge für ein Signal bekannter Dauer),
  `align_curves` auf einem kleinen synthetischen Paar (sauberes Ziel-Onset vs. verschobenes
  "Gesangs"-Onset) — prüft, dass `aligned_t` innerhalb einer Toleranz der Zielzeit landet.
- `tests/test_e2e_phase3.py` (neu, analog zu `test_e2e_phase1.py`), nutzt die bestehende
  synthetische Fixture (`tests/fixtures/generate_fixtures.py`: 5-Noten-Melodie C-E-G-E-C, Note 2
  wird 150ms zu früh gesungen, Note 3 driftet -100 Cent über die letzten 300ms):
  - Kernassertion: am Sungenen-Frame, an dem Note 2 tatsächlich einsetzt (`t ≈ 1.85s`), liegt
    `aligned_t - t` in einem Toleranzband um `+0.15s` (z.B. `0.10 ≤ aligned_t - t ≤ 0.20`).
  - Regressionsschutz: für unveränderte Noten (0 und 4) bleibt `aligned_t - t` nahe 0
    (z.B. `< 0.05s`) — verhindert einen DTW, der pauschal alles verschiebt.
- `mobile/test/session_state_test.dart`: neue Tests für `align()` in beiden Modi
  (`ReferenceSource.midi` und `ReferenceSource.recording`), inklusive eines Fehlerfall-Tests, der
  bestätigt, dass `sungCurve`/`targetCurve` bei fehlgeschlagenem Alignment unverändert bleiben.
  Bestehende Assertions auf der `{'curve': [...]}`-Antwortform sind nicht betroffen, da
  `/api/sync/align` eine eigene, andere Antwortform (`{'target_curve', 'sung_curve',
  'target_duration'}`) hat.

## Out of Scope (bewusst nicht Teil dieses Designs)

- Web-Frontend (`frontend/app.js`) bleibt unverändert bei roher, unausgerichteter Anzeige.
- Kein Umschalter roh/ausgerichtet in der UI.
- Kein serverseitiges Caching der Audiodaten oder der berechneten Hüllkurven — jeder Aufruf von
  `/api/sync/align` berechnet alles frisch.
- Keine Wiederverwendung/Vermeidung der doppelten Tonhöhenberechnung zwischen der bestehenden
  Preview (`/api/audio/analyze`) und `/api/sync/align` — als spätere Optimierung vermerkt, nicht
  Teil dieser Runde.
- Phase 4 (Bewertungs-Engine, `backend/scoring/`) bleibt unangetastet; dieses Design legt nur den
  Datenvertrag (`aligned_t`) so an, dass Phase 4 ihn später konsumieren kann.

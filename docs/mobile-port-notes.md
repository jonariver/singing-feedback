# Mobile-Portierung (Android/iOS) — Diskussionsstand

> Status: Diskussionsstand aus einem Gespräch am 2026-08-03, keine Entscheidung. Dient als
> Ausgangspunkt für einen späteren Fork, falls das Projekt Richtung Mobile-App weiterentwickelt
> werden soll. Bezieht sich auf die Architektur wie in `PLAN.md`/`README.md` beschrieben.

## Ausgangslage

Der aktuelle Prototyp ist ein lokaler Python-Prozess (FastAPI + `librosa`/`pyin`,
`pretty_midi`, PyAV), der ein Vanilla-JS/Canvas-Frontend im Browser ausliefert. Bewusstes
Designprinzip: alles läuft lokal, keine Audiodaten verlassen den Rechner, keine dauerhafte
Speicherung (siehe Datenschutz-Abschnitt in `README.md`).

## Optionen, wenn "komplett lokal" ein hartes Muss bleibt

- **Ansatz A — WebView + gehostetes Backend**: am wenigsten Aufwand, aber Audiodaten müssten
  übers Netz zu einem Server → verletzt das "alles lokal"-Prinzip.
- **Ansatz B — Python direkt auf dem Gerät** (z.B. via Chaquopy): bleibt lokal, aber
  `librosa` mitsamt `numba`/`scipy` auf Android zum Laufen zu bringen ist technisch riskant
  und fehleranfällig (native Builds, Paketgröße).
- **Ansatz C — Nativer Rewrite** der DSP-Logik in Kotlin (Android) bzw. Swift (iOS): z.B.
  Pitch-Erkennung mit TarsosDSP, MIDI-Parsing nativ, DTW/Scoring neu implementiert. Bleibt
  lokal und ist am robustesten, aber mit Abstand der größte Aufwand — praktisch ein zweites
  Backend pro Plattform.

## Empfohlener Ansatz, falls "komplett lokal" kein hartes Muss mehr ist

**Ansatz D**: Das bestehende FastAPI-Backend ist bereits eine saubere, plattformunabhängige
JSON-REST-API (`backend/api/routes.py` — Upload, Spur-Auswahl, Pitch-Analyse, keine
HTML-Kopplung). Diese Logik unverändert lassen und irgendwo hosten (z.B. Fly.io, Render,
eigener Server), statt sie nur auf `localhost` laufen zu lassen. Nur der Client wird neu
gebaut:

- Mikrofonaufnahme über die native Recorder-API der Plattform,
- MIDI-Datei-Auswahl/Upload,
- Darstellung der vom Backend gelieferten Pitch-Kurven nativ (z.B. Compose Canvas auf
  Android) als Ersatz für das jetzige `app.js`-Canvas.

Vorteil: die gereifte DSP-Logik (`librosa`, `pretty_midi`, DTW, Scoring, spätere
Claude-Anbindung aus Phase 6) bleibt komplett unangetastet.

**Falls sowohl Android als auch iOS Ziel sind**: nicht zwei native Clients (Kotlin + Swift)
separat bauen, sondern von Anfang an ein plattformübergreifendes Framework wählen (z.B.
Flutter oder React Native), damit ein Codebase für beide Plattformen reicht. Das sollte vor
Beginn der Client-Implementierung feststehen, nicht erst nachträglich entschieden werden —
eine spätere Portierung von nativem Kotlin auf ein Cross-Platform-Framework wäre doppelte
Arbeit.

**Kompromiss bei Ansatz D**: Audiodaten verlassen dann kurzzeitig das Gerät zur Verarbeitung
(ohnehin schon für die Claude-Anbindung in Phase 6 vorgesehen). "Keine dauerhafte
Speicherung" bleibt aber weiterhin problemlos einhaltbar — das Backend müsste nur wie bisher
temporäre Dateien sofort nach der Analyse löschen.

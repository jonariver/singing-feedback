# Singing Feedback MVP — Architektur & Phasenplan

> **Status:** Phase 0 (Skeleton) und Phase 1 (vertikaler Prototyp) sind umgesetzt und getestet
> (siehe `README.md`). Weiter geht es mit Phase 2 (bessere Spurerkennung & Transposition).

## Context

Ziel ist ein lokal auf Windows laufender Prototyp, der gesungene Interpretationen mit einer
selbst besorgten MIDI-Referenzmelodie vergleicht und über Claude priorisiertes, zeitbezogenes
Feedback samt Übungen liefert. Das Projektverzeichnis ist aktuell leer (Greenfield) — es gibt
keinen bestehenden Code, an dem sich orientiert werden könnte. Wichtige Leitplanken aus der
Anforderung: keine Nutzerkonten/DB/Bezahlung, keine dauerhafte Speicherung von Audiodateien,
kein automatischer Download geschützter Musik, API-Key nie im Frontend, Claude erhält nur
strukturierte Analysewerte statt Audiodateien, klare Trennung von MIDI-Analyse, Tonhöhenerkennung,
Synchronisation, Bewertung und Feedback.

Bestätigte Grundsatzentscheidungen (per Rückfrage geklärt):
- **Claude-Integration**: automatischer Backend-Aufruf der Anthropic API (Key nur serverseitig
  in `.env`, nie im Browser).
- **UI-Shell**: lokaler FastAPI-Server + automatisches Öffnen im Standardbrowser (kein Electron/
  pywebview in der MVP-Phase).

## Architektur & Tech-Stack

**Grundprinzip:** Ein einziger lokaler Python-Prozess (FastAPI + Uvicorn) dient als Backend und
liefert ein schlankes HTML/JS-Frontend (Vanilla JS + Canvas für die Pitch-Kurven, kein Build-Step
nötig). Start über ein einfaches Skript/`.bat`, das den Server hochfährt und den Browser öffnet.
Warum Python: die gesamte DSP/MIDI-Landschaft (librosa, pretty_midi, DTW) ist hier am reifsten;
ein Node/Electron-Stack hätte hier keine Vorteile und mehr Packaging-Aufwand.

**Warum Browser-UI statt natives GUI:** Mikrofonaufnahme läuft bequem über die
`MediaRecorder`-Browser-API (kein PyAudio/sounddevice-Treiberrisiko unter Windows), und
Canvas/SVG erlauben die gewünschte anklickbare Timeline mit Farbkodierung ohne GUI-Toolkit-
Beschränkungen.

### Module (klar getrennt, einzeln testbar)

```
backend/
  midi_analysis/     # Parsing, Spur-Kandidaten-Erkennung, Vorschau-Synthese, Transposition
  pitch_detection/   # librosa pYIN Wrapper -> Zeit/Frequenz/Confidence-Serie
  sync/              # DTW-Ausrichtung Aufnahme <-> MIDI-Referenz
  scoring/           # Vergleich, Cent-Abweichung, Timing, Stabilität, Drift, Glides, Pausen
  feedback/          # JSON -> Claude-Prompt (Übungskatalog), Anthropic-Client, Response-Parsing
  api/               # FastAPI-Routen, Session-State (in-memory, kein DB), Cleanup temporärer Dateien
  exercises/         # kuratierter Übungskatalog (YAML/JSON), von feedback/ referenziert
frontend/
  index.html, app.js, styles.css   # Upload, Spur-/Transpositionsauswahl, Recorder, Pitch-Overlay,
                                     # anklickbare Timeline, Feedback-Anzeige
tests/
  fixtures/           # synthetisch erzeugte Test-MIDI + Test-WAV (siehe Risiko-Abschnitt)
```

### Kernbibliotheken
- `fastapi` + `uvicorn` — Server
- `pretty_midi` — MIDI-Parsing (Noten, Instrumente, Tempo, Tonhöhenbereich pro Spur)
- `librosa` (inkl. `pyin`) — Tonhöhenerkennung; leichtgewichtiger als CREPE (kein TensorFlow/Torch
  nötig), als Modul austauschbar falls später mehr Genauigkeit gewünscht ist
- `numpy`/`scipy` — DSP-Grundlagen, eigener DTW-Featurevergleich
- `soundfile` + `av` (PyAV) — WAV/MP3 lesen und vom Browser gelieferte WebM/Opus-Aufnahmen ohne
  separate ffmpeg-Installation dekodieren (PyAV bringt statische ffmpeg-Libs im Wheel mit)
- `anthropic` (offizielles SDK) — Claude-Aufruf, Key aus `.env` (z.B. via `python-dotenv`),
  ausschließlich serverseitig
- `pytest` — Tests je Modul

### Datenfluss (Kurzfassung)
1. Frontend schickt Songtitel/Interpret → Backend generiert Suchlinks (konfigurierbare
   Link-Provider: MuseScore, MIDI Files, …) — keine Downloads.
2. Nutzer lädt `.mid` hoch → `midi_analysis` parst Spuren, bewertet Kandidaten heuristisch,
   liefert Metadaten + kurze Sinus-Vorschau (kein Soundfont nötig) pro Kandidat an Frontend.
3. Nutzer wählt Spur + optionale Transposition (Halbtonschritte) → Zielmelodie als
   Zeit/Tonhöhe-Kurve materialisiert.
4. Nutzer nimmt im Browser auf oder lädt WAV/MP3 hoch → Backend dekodiert, hält Audio nur
   in-memory/temp (löscht nach Verarbeitung).
5. `pitch_detection` erzeugt gesungene Pitch-Kurve.
6. `sync` richtet beide Kurven per DTW aus (Feature: Energie-/Onset-Hüllkurve statt Rohtonhöhe,
   siehe Risiken).
7. `scoring` erzeugt strukturierte JSON-Messwerte mit Zeitstempeln.
8. `feedback` schickt nur dieses JSON (keine Audiodaten) an Claude, wählt bevorzugt aus dem
   kuratierten Übungskatalog, formuliert max. 3 priorisierte Punkte mit klarer Trennung
   Messwert/Interpretation/Vermutung.
9. Frontend zeigt farbkodierte Timeline (grün/gelb/rot), anklickbare Stellen, Feedback-Karten.

## Technisch riskanteste Punkte

1. **Automatische Gesangsspur-Erkennung in MIDI** — Heuristiken (monophon, Stimmumfang,
   Notendichte, Dauer, Name) müssen kombiniert und kalibriert werden; Fehlklassifikation ist
   der wahrscheinlichste Quality-Bug. Mitigation: mehrere Kandidaten mit Scores anzeigen statt
   einer einzigen automatischen Wahl, Nutzer entscheidet final.
2. **Robustheit der Tonhöhenerkennung** bei „trockenen“, aber realistisch verrauschten
   Handy-/Mikrofonaufnahmen (Atmen, Konsonanten, Raumhall). pYIN ist der pragmatische Start;
   Stabilitäts-/Vibrato- vs. Drift-Erkennung braucht eigene Nachbearbeitung der rohen
   pYIN-Ausgabe.
3. **Synchronisation trotz Timing-Abweichungen** — DTW direkt auf absoluter Tonhöhe scheitert,
   wenn der Nutzer falsch singt (genau das, was gemessen werden soll). Geplanter Ansatz: DTW auf
   einer tonhöhen-unabhängigen Rhythmus-/Energiehüllkurve (Onsets), erst danach Tonhöhenvergleich
   auf der ausgerichteten Zeitachse. Muss früh mit synthetischen Testfällen validiert werden.
4. **Browser-Aufnahmeformat** — `MediaRecorder` liefert i.d.R. WebM/Opus; zuverlässiges Dekodieren
   unter Windows ohne separate ffmpeg-Installation (Lösung: PyAV-Wheel, das ffmpeg-Libs
   mitbringt) muss früh getestet werden.
5. **Schwellenwerte grün/gelb/rot und „Zielnote getroffen“** — musikalische Kalibrierung
   (wie viele Cent gelten als „leicht“ vs. „deutlich“ daneben) ist zunächst eine begründete
   Annahme, die iterativ angepasst wird.
6. **Claude-Prompt-Disziplin** — sicherstellen, dass Ursachen wie „Stützprobleme“ nur als
   vorsichtige Vermutung erscheinen und nie als Diagnose; das gehört in Systemprompt +
   nachgelagerte Validierung, nicht nur in die Anweisung.

## Getroffene Annahmen (dokumentiert, bei Bedarf korrigierbar)

- Tonhöhenerkennung startet mit `librosa.pyin` (kein CREPE/TensorFlow in der MVP-Phase).
- Spur-Vorschau nutzt einen einfachen eingebauten Sinus-/Obertonsynthesizer statt Soundfont/
  FluidSynth, um zusätzliche Abhängigkeiten zu vermeiden.
- Für reproduzierbare Tests wird kein geschütztes Lied verwendet, sondern ein synthetisch
  erzeugtes Test-MIDI (kurze, einfache Melodie) plus eine synthetisch generierte „Gesangs“-WAV
  (Sinuskurve, die der Melodie folgt, mit bewusst eingebauten Abweichungen: zu tief, zu früh,
  driftendes Phrasenende). Das erfüllt Akzeptanzkriterium 10, ohne Urheberrecht zu berühren.
- Grün/Gelb/Rot-Schwellen zunächst z.B. ±15 Cent (grün), ±50 Cent (gelb), darüber rot —
  anpassbar, sobald reale Testaufnahmen vorliegen.
- Kurze Ausschnitte (20–60s) zuerst; keine Vollsong-Optimierung in Phase 1–8.

## Phasenplan

**Phase 0 — Projekt-Skeleton**
FastAPI-Grundgerüst, Ordnerstruktur wie oben, `.env`-Handling für `ANTHROPIC_API_KEY`,
Start-Skript (öffnet Browser automatisch), leeres Frontend-Grundgerüst, `pytest`-Setup.

**Phase 1 — Vertikaler Prototyp (erster funktionierender Durchstich)**
Ziel exakt wie gewünscht: MIDI hochladen → Spurliste (noch ohne feine Heuristik-Scores, nur
Basisfilter monophon/Instrument) → Spur auswählen → kurze WAV hochladen → pYIN-Pitchkurve
berechnen → beide Kurven (Ziel aus MIDI, Ist aus Gesang) roh nebeneinander in einem einfachen
Chart darstellen (noch ohne DTW, ohne Farbkodierung, ohne Claude). Automatisierter Test mit den
synthetischen Fixtures aus den Annahmen. Damit ist die Kernpipeline End-to-End belegt, bevor
weitere Komplexität dazukommt.

**Phase 2 — Bessere Spurerkennung & Transposition**
Volle Heuristik-Bewertung (Stimmumfang, Notendichte, Dauer-Plausibilität, Name-Matching),
Mehrfachkandidaten mit Hörprobe (Sinus-Synth) im Frontend, Warnhinweis bei fehlender
Gesangsspur, Transpositions-Eingabe.

**Phase 3 — Robuste Synchronisation**
DTW auf Onset-/Energie-Feature statt Rohtonhöhe, Mapping der Zeitachsen, Validierung anhand der
synthetischen Testfälle mit absichtlichem Timing-Versatz.

**Phase 4 — Bewertungs-Engine**
Cent-Abweichung, verfehlte Zielnoten, zu frühe/späte Einsätze, Stabilität gehaltener Töne,
Phrasenend-Drift, Glides, Stimmumfang der Aufnahme, Pausen/Atemstellen — als strukturiertes JSON
mit Zeitstempeln.

**Phase 5 — Visuelle Gegenüberstellung**
Canvas-Overlay Soll/Ist-Kurve, grün/gelb/rot-Einfärbung, anklickbare Zeitstellen mit
Zielton/Abweichungsanzeige, Sprung zur passenden Audiostelle.

**Phase 6 — Claude-Feedback**
Kuratierter Übungskatalog (YAML/JSON), Prompt-Aufbau mit klarer Trennung Messwert/Interpretation/
Vermutung, Anthropic-API-Aufruf serverseitig, Parsing zu max. 3 priorisierten Punkten inkl.
Übung und optionaler Wiederholungsaufgabe.

**Phase 7 — Song-Eingabe & Link-Provider**
Songtitel/Interpret-Eingabe, konfigurierbare Link-Provider (MuseScore, MIDI Files, weitere),
Zusammenführen aller bisherigen Teile zum vollen 13-Schritte-Ablauf.

**Phase 8 — Datenschutz-Härtung & Dokumentation**
Sicherstellen, dass keine Audiodatei den Prozess überlebt (Temp-Cleanup, keine Logs mit
Rohaudio), Testaufnahme + Ablauf für Akzeptanzkriterium 10 dokumentieren.

## Verifikation je Phase

- Jede Phase bekommt `pytest`-Unit-Tests für ihr Modul (MIDI-Parsing, Pitch-Erkennung an
  synthetischem Signal mit bekannter Frequenz, DTW-Alignment-Genauigkeit an synthetischem
  Versatz, Scoring-Grenzwerte, Feedback-JSON-Schema).
- Phase 1 zusätzlich: End-to-End-Skript, das die synthetischen Fixtures durch die gesamte
  Pipeline (bis zum jeweiligen Phasenstand) schickt und Zwischenergebnisse ausgibt/plottet —
  das ist zugleich die „dokumentierte Testaufnahme“ aus Akzeptanzkriterium 10.
- Manuelle Prüfung im Browser nach Phase 1 und Phase 5 (Upload-Flow, Aufnahme-Flow,
  Visualisierung) mit der Test-Fixture und optional einer echten eigenen kurzen Aufnahme.

## Nächster Schritt nach Freigabe

Start mit Phase 0 (Skeleton) direkt gefolgt von Phase 1 (vertikaler Prototyp), da dies laut
Vorgabe der erste konkrete Meilenstein ist.

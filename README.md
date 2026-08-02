# Singing Feedback — lokaler Prototyp

Vergleicht eine Gesangsaufnahme mit einer selbst besorgten MIDI-Referenzmelodie und liefert
später zeitbezogenes Feedback samt Übungen. Läuft vollständig lokal (kein Server, keine
Nutzerkonten, keine dauerhafte Speicherung von Audiodateien). Architektur- und Phasenplan:
siehe `PLAN.md`.

**Aktueller Stand: Phase 1** — vertikaler Prototyp: MIDI hochladen, Spur wählen, kurze
Gesangsaufnahme hochladen, beide Tonhöhenkurven roh nebeneinander anzeigen (noch ohne
Zeitausrichtung/DTW, Bewertung oder Claude-Feedback).

## Setup (einmalig)

```bash
python -m venv .venv
# Windows: .venv\Scripts\pip install -r requirements.txt
.venv/bin/pip install -r requirements.txt
cp .env.example .env   # optional in Phase 1, wird erst ab Phase 6 fuer Claude benoetigt
```

## Starten

```bash
# Windows:
start.bat
# oder direkt:
.venv/bin/python run.py
```

Startet einen Server auf `http://127.0.0.1:8000` (nur lokal erreichbar) und öffnet automatisch
den Standardbrowser.

## Tests

```bash
.venv/bin/python -m pytest tests/ -v
```

Die Tests nutzen ausschließlich synthetisch erzeugte, urheberrechtsfreie Testdaten
(`tests/fixtures/generate_fixtures.py`): eine kurze Fantasiemelodie als MIDI plus eine
generierte "Gesangs"-WAV mit drei bewusst eingebauten Abweichungen (zu tiefe Note, zu früher
Einsatz, absackendes Phrasenende). `tests/test_e2e_phase1.py` fährt damit den kompletten
Phase-1-Weg (MIDI-Upload → Spurwahl → Zielkurve → Tonhöhenerkennung der Aufnahme) und prüft,
dass die Abweichungen tatsächlich messbar sind — das ist die dokumentierte, reproduzierbare
Testaufnahme für den Prototyp.

Die Fixture-Dateien selbst werden nicht eingecheckt (siehe `.gitignore`), sondern bei Bedarf
per `python tests/fixtures/generate_fixtures.py` deterministisch neu erzeugt.

## Manuell ausprobieren

1. Server starten (siehe oben).
2. `tests/fixtures/test_reference.mid` hochladen (ggf. vorher per Skript erzeugen).
3. Die erkannte Spur "Vocal" auswählen.
4. `tests/fixtures/test_vocal.wav` als Aufnahme hochladen.
5. Im Diagramm erscheinen beide Tonhöhenkurven; die eingebauten Abweichungen sind sichtbar
   (Einsatz der dritten Note etwas früher, Ende der vierten Note driftet nach unten ab).

## Projektstruktur

```
backend/
  midi_analysis/   MIDI-Parsing, Spurkandidaten, Zielkurve      (Phase 1)
  pitch_detection/ pYIN-Tonhöhenerkennung der Aufnahme           (Phase 1)
  sync/            DTW-Ausrichtung Aufnahme <-> MIDI             (ab Phase 3)
  scoring/         Cent-Abweichung, Timing, Stabilität, Drift    (ab Phase 4)
  feedback/        Claude-Aufruf, Übungskatalog-Auswahl          (ab Phase 6)
  api/              FastAPI-Routen, In-Memory-Session
  exercises/       kuratierter Übungskatalog (catalog.yaml)
frontend/          Vanilla HTML/JS/Canvas, kein Build-Step
tests/             Unit- und End-to-End-Tests + Fixture-Generator
```

## Datenschutz

- Keine Datenbank, keine Nutzerkonten.
- Hochgeladene Audiodateien werden nur in einer temporären Datei zwischengehalten und sofort
  nach der Analyse gelöscht.
- MIDI-Sessions leben nur im Arbeitsspeicher (kein Prozess-Neustart-übergreifendes Persistieren)
  und verfallen zusätzlich nach 30 Minuten.
- Ein `ANTHROPIC_API_KEY` (ab Phase 6) wird ausschließlich serverseitig aus `.env` gelesen und
  landet nie im Frontend-Code.

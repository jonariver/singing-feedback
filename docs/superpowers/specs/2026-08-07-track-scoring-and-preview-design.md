# Design: Bessere Spurerkennung & Hörprobe (Phase 2)

**Datum:** 2026-08-07
**Status:** Genehmigt, bereit für Plan

## Kontext

`PLAN.md` Phase 2 ("Bessere Spurerkennung & Transposition") ist bislang nur teilweise umgesetzt.
Bereits vorhanden aus Phase 1 (`backend/midi_analysis/parser.py`):

- Basisfilter `plausible` (Schlagzeug und `note_count < MIN_PLAUSIBLE_NOTE_COUNT` sind hart
  implausibel), Warnungen als Freitext
- `monophonic`-Erkennung, `name_hint_match` als Bool
- Sortierung per Tuple-Key (`not name_hint_match, not plausible, not monophonic, -note_count`)
- Warnhinweis im Frontend, wenn keine Spur `plausible` ist (`SessionState.uploadMidi`)
- Transpositions-Eingabe (`TransposeControl`)

Fehlend und Gegenstand dieser Spec:

1. Eine echte gewichtete Score-Berechnung statt der Tuple-Sortierung, inkl. zwei neuer
   Kriterien: Stimmumfang-Plausibilität, Notendichte, Dauer-Plausibilität relativ zur Songlänge.
2. Eine Hörprobe (Sinus-/Obertonsynthesizer) pro Kandidat im Frontend — existiert im Code noch
   nicht (die "Getroffene Annahmen"-Sektion in `PLAN.md` legt den Synthesizer-Ansatz bereits
   fest, nur die Umsetzung fehlt).

## Teil A: Gewichteter Score

`TrackCandidate` bekommt ein neues Feld `score: float` (0–100), berechnet in
`list_track_candidates()` aus 5 Teilkriterien à maximal 20 Punkten:

| Kriterium | Punkte | Berechnung |
|---|---|---|
| Namenstreffer | 20 (flat) | `name_hint_match` |
| Monophonie | 20 (flat) | `monophonic` |
| Stimmumfang-Plausibilität | 20 × Anteil | Anteil von `[pitch_min, pitch_max]`, der innerhalb eines großzügigen Gesangsfensters (MIDI 43–84, ≈ G2–C6) liegt |
| Notendichte | 20 (Fenster) | volle Punktzahl bei ~0,5–4 Noten/Sekunde, linear abfallend auf 0 außerhalb (unterhalb wie oberhalb) |
| Dauer-Plausibilität | 20 × Verhältnis | `min(1, duration_seconds / längste_Spur_Dauer / 0.3)` — volle Punktzahl ab 30% der Dauer der längsten Spur der Datei |

Schlagzeugspuren bekommen `score = 0` direkt (statt in die Formel einzugehen — bei `is_drum`
sind die übrigen Kriterien ohnehin nicht aussagekräftig). Bei `note_count == 0` ebenfalls
`score = 0` (kein Kandidat mit Noten zum Bewerten).

Die bestehenden harten `plausible`-Regeln (Schlagzeug, zu wenige Noten) und die
Warnungs-Texte bleiben **unverändert** — der Score ist ein zusätzliches Signal für Sortierung
und Anzeige, kein Ersatz für die bestehende Plausibilitätsprüfung.

**Sortierung:** `candidates.sort(key=lambda c: -c.score)` ersetzt die bisherige Tuple-Sortierung.

**API:** `TrackCandidate.to_dict()` bekommt zusätzlich `"score": round(float(self.score), 1)`.

**Mobile:** `TrackCandidate` (Dart) bekommt `final double score`. `TrackCandidateCard` zeigt einen
Prozent-Badge mit Farbcodierung — grün ≥70, gelb 40–69, rot <40 — konsistent mit dem
bestehenden Grün/Gelb/Rot-Schema aus `PitchChart`/`ScoreSummaryView`. Die Farb-/Stufen-Zuordnung
wird als reine Funktion implementiert (analog zu `colorForSungPoint` aus der
Pitch-Chart-Coloring-Feature), damit sie isoliert unit-testbar ist, statt inline im Widget-Build
zu stecken.

## Teil B: Hörprobe (Sinus-Synth)

**Backend:** Neues Modul `backend/midi_analysis/preview.py`:

```
synthesize_track_preview(
    pm: pretty_midi.PrettyMIDI,
    track_index: int,
    transpose_semitones: int = 0,
    max_seconds: float = 15.0,
    sample_rate: int = 22050,
) -> bytes  # WAV
```

Rendert additiv Sinuston + zwei Obertöne (halbe/viertel Amplitude) pro Note im gewählten
Zeitfenster `[0, max_seconds]`, mit kurzem linearen Attack/Release (~10ms) pro Note gegen
Knackgeräusche an Notengrenzen. Kein externer Soundfont/FluidSynth (siehe `PLAN.md`s bestehende
Grundsatzentscheidung). Kodierung als WAV via `soundfile` (bereits Projektabhängigkeit) in einen
`io.BytesIO`.

Notenauswahl fürs Preview-Fenster: alle Noten der Spur, deren `start < max_seconds`, dabei am
Fensterende hart abgeschnitten (kein Ausblenden über das Fenster hinaus nötig, `max_seconds` ist
eine reine Vorschau, keine musikalisch korrekte Phrasierung).

**Endpoint:** `GET /midi/{session_id}/track-preview?track_index=N&transpose=0`, analog zu
`GET /midi/{session_id}/track-curve` — gleiche Session-Wiederverwendung
(`MIDI_SESSIONS[session_id]`), gleiche Fehlerbehandlung bei ungültigem `track_index`. Response:
`Response(content=wav_bytes, media_type="audio/wav")`.

Kein Rate-Limit auf diesem Endpoint — analog zu `track-curve` ist die Arbeit durch
`max_seconds` fest gedeckelt und erfordert bereits eine bestehende (beim Upload
ratenlimitierte) Session; ein Angreifer kann daraus keine unbounded Last erzeugen.

**Mobile:**

- `MidiApi` bekommt `Future<Uint8List> fetchTrackPreview(sessionId, trackIndex, transpose)`.
- `SessionState` bekommt einen Cache `Map<int, Uint8List> _trackPreviewCache` (Key:
  `track_index`), geleert bei jedem neuen `uploadMidi()`. Eine Methode
  `Future<Uint8List> previewBytesForTrack(int index)` liefert aus dem Cache oder holt und
  cacht bei Cache-Miss.
- `TrackCandidateCard` bekommt einen Play/Pause-Button (analog zu `PlaybackButton`), der beim
  ersten Tap lazy über `previewBytesForTrack` lädt (Ladeindikator während des Fetches) und dann
  über den bereits zentralisierten `SessionState`-Player abspielt/pausiert — **kein** neuer
  eigener `AudioPlayer` in der Karte, um nicht dieselbe Bugklasse (mehrere Player spielen
  gleichzeitig) zu reproduzieren, die die letzte Playback-Zentralisierung genau behoben hat.
  Icon-Status pro Karte über `identical()`-Check auf die gecachten Bytes, wie bei
  `PlaybackButton.isPlayingAudio(bytes)`.
- Fehler beim Preview-Fetch: Inline-Fehlertext auf der Karte, blockiert die Spurauswahl nicht.

## Testing

**Backend:**
- `score_candidate`/`list_track_candidates`: Monotonie-Tests (Namenstreffer erhöht Score,
  Monophonie erhöht Score, Schlagzeug → 0, sehr kurze Spur relativ zur längsten → niedriger
  Dauer-Anteil-Score, Notendichte außerhalb des Fensters senkt Score in beide Richtungen).
- `synthesize_track_preview`: liefert gültige, dekodierbare WAV-Bytes; Dauer ist auf
  `max_seconds` gedeckelt auch bei längeren Spuren; leere Spur liefert Stille statt Fehler.
- Kein dedizierter HTTP-Level-Test für `GET /midi/{session_id}/track-preview` (Korrektur
  gegenüber der ursprünglichen Formulierung dieser Sektion, die fälschlich einen analogen
  bestehenden `track-curve`-Endpoint-Test unterstellte — den gibt es nicht: dieses Repo hat
  aktuell keinen einzigen `TestClient`-basierten Test, alle Endpunkte werden nur indirekt über
  ihre zugrunde liegenden Funktionen getestet, siehe z.B. `tests/test_e2e_phase1.py`). Bewusst
  konsistent mit diesem bestehenden Muster: `synthesize_track_preview()` selbst ist über
  `tests/test_midi_preview.py` vollständig abgedeckt (gültige WAV-Bytes, Dauer-Deckelung,
  Stille bei leerer Spur, ungültiger `track_index` wirft `ValueError`); die Route in
  `routes.py` bleibt ungetestet dünn, wie jede andere Route in diesem Projekt auch.

**Mobile:**
- Reine Score→Farbe/Label-Mapping-Funktion: Unit-Tests für alle drei Schwellenbereiche.
- `SessionState`-Tests: Cache wird bei `uploadMidi()` geleert, `previewBytesForTrack` liefert
  aus Cache bei zweitem Aufruf ohne erneuten Netzwerk-Call (Fake-`MidiApi` mit Call-Zähler),
  Preview-Playback delegiert an den zentralisierten Player (gleiches Testmuster wie die
  bestehenden Playback-Tests aus `session_state_test.dart`).

## Out of Scope

- Keine Änderung an der bestehenden `plausible`/Warnungs-Logik (Teil A ergänzt nur den Score).
- Keine echte Instrumentierung/Soundfont — bleibt beim Sinus-/Obertonsynthesizer laut
  `PLAN.md`.
- Keine Persistenz der Preview-Bytes über die Session-Lifetime hinaus (gleiches Cleanup-Modell
  wie bestehende In-Memory-Sessions).

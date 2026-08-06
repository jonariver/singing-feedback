# Sprung zur Audiostelle aus dem Feedback

Status: Design abgestimmt am 2026-08-06, bereit für Implementierungsplan.

## Kontext

Phase 6 (`backend/feedback/`, `POST /api/feedback`, `FeedbackSection`) liefert
bis zu drei priorisierte Feedback-Punkte (`problem`, `technik`, `uebung`,
`wiederholungsaufgabe`), aber ohne jeden Zeitbezug zur Aufnahme. Der Nutzer
möchte von einer Feedback-Karte direkt zur Stelle in der eigenen Aufnahme
springen können, die das Problem ausgelöst hat, statt die Aufnahme manuell
danach absuchen zu müssen.

`backend/scoring/score.py` berechnet pro Note bereits die zugeordneten
Gesangs-Frames (`attribute_sung_frames`) — deren `t`-Feld (nicht
`aligned_t`, das ist Zielmelodie-Zeit) ist die tatsächliche Position in der
eigenen Aufnahme und bereits vorhanden, muss nur noch durchgereicht werden.

**Geprüfte Invariante:** `t` im Pitch-Curve (`pitch_detection/pyin.py`,
`librosa.times_like`) entspricht exakt der Position in genau den
Audio-Rohbytes, die `audio_io.py::load_audio_signal` dekodiert hat — keine
Trimm- oder Offset-Logik am Anfang, weder backend- noch mobile-seitig vor
dem Upload (nur eine Kappung am Ende bei `max_seconds`). Das sind exakt
dieselben Bytes (`sungAudioBytes`), die `PlaybackButton` heute abspielt.
**Diese Invariante ist die Grundlage des ganzen Features — bricht sie
(z.B. durch künftig eingeführtes Silence-Trimming vor der
Pitch-Erkennung), wird jeder Sprung falsch positioniert.** Ein Kommentar an
`load_audio_signal` sollte künftige Änderungen darauf hinweisen.

## Architektur / Datenfluss (Backend)

`backend/scoring/score.py` ergänzt das Note-Ergebnis um ein neues Feld
`sung_t`: das `t` des ersten der Note zugeordneten Gesangs-Frames
(`attributed[0]["t"]`), oder `null`, wenn keine Frames zugeordnet sind
(z.B. komplett verfehlte Noten).

`backend/feedback/prompt.py`s `build_prompt_context()` reicht `sung_t` in
jedem Eintrag von `flagged_notes` einfach durch — fließt **nicht** in den
an Claude gesendeten Prompt-Text ein (`build_prompt_text()` liest es
nicht), ist rein für die spätere Zuordnung in `generate.py` gedacht.

`backend/feedback/generate.py` bekommt eine Kategorie-Zuordnung, die
dieselbe Bedeutung wie die bestehenden `_PROBLEM_TAG_*`-Konstanten aus
`score.py` hat (Katalog-ID → welches Note-Feld sie auslöst):
- `"timingprobleme"` → `timing_classification != "on_time"`
- `"absinkende_phrasenenden"` → `phrase_end_drift_flag`
- `"instabile_lange_toene"` → `stability_flag`
- `"unsaubere_einsaetze"` → `missed` oder `cents_classification == "red"`
- `"haeufiges_hineingleiten"` → aktuell nie erfüllt (Glide-Erkennung noch
  nicht gebaut, siehe `problem_tags`-Lücke in `score.py`)

Für jeden von Claude zurückgegebenen Punkt sucht `generate.py` die erste
passende Note (in `score_result["notes"]`-Reihenfolge) mit `sung_t != null`,
**die noch nicht von einem vorherigen Punkt derselben Antwort verwendet
wurde** (ein `used_notes`-Set aus Noten-Indizes, über die gesamte
Punkt-Verarbeitungsschleife hinweg geführt) — damit bei mehreren Punkten
derselben Kategorie nicht alle zur gleichen Stelle springen. Findet sich
keine unverbrauchte Note mit Zeitstelle, bekommt der Punkt `jump_to_t:
null`.

Response-Erweiterung: jeder Punkt in `{"feedback": {"points": [...]}}`
bekommt ein neues Feld `jump_to_t` (Sekunden, `float | null`).

## Mobile-Architektur (Player-Zentralisierung)

`SessionState` bekommt eine zentrale `AudioPlaybackController`-Instanz mit
`play(Uint8List bytes)`, `playFrom(Uint8List bytes, Duration position)`,
`pause()`, `stop()` — plus beobachtbaren `isPlaying`-State
(`notifyListeners()`), damit alle Widgets denselben Wiedergabezustand
sehen. Zentrale Disposal beim Verlassen des Screens.

`PlaybackButton` wird umgebaut: statt einen eigenen `AudioPlayer` zu
kapseln, ruft er nur noch `session.play(...)`/`session.pause()` auf und
liest `session.isPlaying` statt eigenen lokalen State zu führen — sein
äußeres Verhalten (Icon, Fehlermeldung, Busy-Guard-Zeitpunkt) bleibt
unverändert.

Jede `_FeedbackPointCard` bekommt einen kleinen Sprung-Button, nur
sichtbar wenn `point.jumpToT != null`. Tap ruft
`session.playFrom(session.sungAudioBytes!, Duration(milliseconds: ((max(0, jumpToT - 0.5)) * 1000).round()))`
auf — der 0,5-Sekunden-Vorlauf wird **mobile-seitig** angewendet, nicht im
Backend, damit `jump_to_t` der reine Notenbeginn bleibt (wiederverwendbar,
z.B. für eine spätere Chart-Klick-Funktion mit eigenem/keinem Vorlauf) und
audioplayers' `play(..., position:)` direkt ab dieser Stelle abspielt
(kein separater `seek()`-Aufruf nötig).

## Edge Cases

- Kein `jumpToT` → kein Sprung-Button auf der Karte, keine Fehlermeldung
  (passt zum bestehenden Muster: fehlende Daten rendern einfach nichts).
- Sprung während laufender normaler Wiedergabe → `playFrom()` unterbricht
  die laufende Wiedergabe automatisch und startet an der neuen Stelle, da
  beide Widgets dieselbe zentrale Player-Instanz steuern — kein
  Doppel-Playback möglich.
- Mehrere Punkte derselben Kategorie → durch das `used_notes`-Set bekommt
  jede Karte (soweit möglich) eine andere Zeitstelle.

## Testing

**Backend:** Tests für `score.py`s neues `sung_t`-Feld (Note mit
zugeordneten Frames → erstes `t`; Note ohne zugeordnete Frames → `null`).
Tests für `generate.py`s Kategorie-Zuordnung und `used_notes`-Logik
(mehrere Noten derselben Kategorie → erste mit Zeitstelle gewinnt;
verfehlte Note ohne Zeitstelle wird übersprungen; zwei Punkte derselben
Kategorie bekommen unterschiedliche Noten, falls verfügbar; keine
unverbrauchte Note übrig → `jump_to_t: null`).

**Mobile:** `SessionState`-Tests für `play`/`playFrom`/`pause` mit einem
gefakten `AudioPlaybackController` (dieselbe Fake-Struktur wie bisher in
`playback_button_test.dart`, jetzt auf `SessionState`-Ebene). Widget-Tests
für den umgebauten `PlaybackButton` (jetzt dünner, delegiert an
`SessionState` — bestehende Tests müssen weiter grün sein, ggf. angepasst
an die neue Delegation) und für den neuen Sprung-Button auf
`_FeedbackPointCard` (sichtbar/unsichtbar je nach `jumpToT`, löst
`playFrom` mit dem richtigen, um 0,5s reduzierten Zeitpunkt aus).

## Out of Scope (bewusst nicht Teil dieses Designs)

- Keine anklickbaren Zeitstellen im Pitch-Chart (der ältere, separate
  Phase-5-Restpunkt) — nur der Sprung von Feedback-Karten aus. Die
  zentrale `AudioPlaybackController`-Architektur macht eine spätere
  Chart-Klick-Funktion aber einfacher anzubinden.
- Keine mehreren Sprungziele pro Karte — nur die erste (unverbrauchte)
  passende Stelle.
- Keine Änderung an der Katalog-Struktur oder den `problem_tags`-Werten
  selbst.

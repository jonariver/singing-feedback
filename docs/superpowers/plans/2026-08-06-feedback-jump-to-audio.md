# Sprung zur Audiostelle aus dem Feedback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Von einer Claude-Feedback-Karte aus per Tap zur Stelle in der eigenen Aufnahme springen, die das jeweilige Problem ausgelöst hat.

**Architecture:** Backend: `score.py` ergänzt pro Note die tatsächliche Position in der eigenen Aufnahme (`sung_t`), `generate.py` ordnet jedem zurückgegebenen Feedback-Punkt die erste passende, noch unverbrauchte Note dieser Kategorie zu (`jump_to_t`). Mobile: `SessionState` bekommt einen zentralen, injizierbaren Audio-Player (lazy konstruiert, damit bestehende Tests ohne Wiedergabe-Bezug keinen echten `AudioPlayer` anstoßen), `PlaybackButton` wird auf Delegation an `SessionState` umgebaut, Feedback-Karten bekommen einen Sprung-Button mit 0,5s Vorlauf.

**Tech Stack:** Python/FastAPI (Backend), Flutter/Dart mit `provider` und `audioplayers` (Mobile).

## Global Constraints

- Geprüfte Invariante: `t` im Pitch-Curve entspricht exakt der Position in den Audio-Rohbytes (`sungAudioBytes`), die `PlaybackButton` abspielt — keine Trimm-/Offset-Logik irgendwo in der Kette (siehe Design-Spec). Diese Invariante wird von diesem Plan vorausgesetzt, nicht neu geprüft.
- Sprungziel = erste betroffene Stelle einer Kategorie, chronologisch, unter den Noten mit tatsächlicher Zeitstelle (`sung_t != null`).
- Mehrere Feedback-Punkte derselben Kategorie bekommen (soweit möglich) unterschiedliche Sprungziele — bereits verwendete Noten werden übersprungen.
- Sprung-Button startet die Wiedergabe direkt (kein reines Seek+Pause), mit 0,5 Sekunden Vorlauf: `max(0, jumpToT - 0.5)`. Der Vorlauf wird **mobile-seitig** angewendet, nicht im Backend.
- `jump_to_t` bleibt `null`, wenn keine passende, unverbrauchte Note mit Zeitstelle existiert — die Karte bekommt dann keinen Sprung-Button (kein Platzhalter, keine Fehlermeldung).
- `SessionState` besitzt genau einen zentralen Audio-Player; `PlaybackButton` (beide Instanzen: Referenzaufnahme UND Gesangsaufnahme) und der neue Sprung-Button teilen sich ihn, sodass nie zwei Wiedergaben gleichzeitig laufen.

---

### Task 1: `sung_t` pro Note berechnen und bis zum Prompt-Kontext durchreichen

**Files:**
- Modify: `backend/scoring/score.py`
- Modify: `backend/feedback/prompt.py`
- Test: `tests/test_scoring.py`
- Test: `tests/test_feedback.py`

**Interfaces:**
- Produces: jedes Element von `score_performance(...)["notes"]` bekommt ein neues Feld `"sung_t": float | None`. Jedes Element von `build_prompt_context(score_result)["flagged_notes"]` bekommt ebenfalls `"sung_t"` (unverändert durchgereicht, fließt nicht in `build_prompt_text()`s Ausgabe ein).
- Consumes: nichts aus späteren Tasks (Grundlage für Task 2).

- [ ] **Step 1: Failing-Test für `score.py`s `sung_t`-Feld schreiben**

Ergänze in `tests/test_scoring.py` den Import-Block (nach der bestehenden `from backend.scoring.timing import ...`-Zeile):

```python
from backend.scoring import score_performance
```

Füge am Ende der Datei an:

```python
def test_score_performance_includes_sung_t_from_first_attributed_frame():
    target_curve = _flat_curve(440.0, 100)  # eine Note, 0.0s-1.0s
    sung_curve = [
        {"t": round(i * 0.01, 3), "hz": 440.0, "voiced": True, "confidence": 0.9,
         "aligned_t": round(i * 0.01, 3)}
        for i in range(50)
    ]
    score = score_performance(target_curve, sung_curve)
    assert score["notes"][0]["sung_t"] == pytest.approx(0.0)


def test_score_performance_sung_t_is_none_when_note_has_no_attributed_frames():
    target_curve = _flat_curve(440.0, 100)
    score = score_performance(target_curve, [])
    assert score["notes"][0]["sung_t"] is None
```

- [ ] **Step 2: Test ausführen, Fehlschlag bestätigen**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/test_scoring.py -v -k sung_t`
Expected: FAIL — `KeyError: 'sung_t'`.

- [ ] **Step 3: `sung_t` in `score.py` ergänzen**

In `backend/scoring/score.py`, im `notes.append({...})`-Block (nach der bestehenden Zeile `"phrase_end_drift": drift,`, vor der schließenden `})`), ergänze:

```python
            "sung_t": attributed[0]["t"] if attributed else None,
```

- [ ] **Step 4: Test ausführen, Erfolg bestätigen**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/test_scoring.py -v -k sung_t`
Expected: PASS, beide neuen Tests grün.

- [ ] **Step 5: Bestehende Tests auf Regression prüfen**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/ -q`
Expected: PASS, keine Regression (`test_e2e_phase4.py`s Fixture-Test prüft einzelne Felder, keinen exakten Dict-Vergleich — das neue `sung_t`-Feld bricht ihn nicht).

- [ ] **Step 6: `_note()`-Testhelfer in `tests/test_feedback.py` um `sung_t` erweitern**

Ersetze in `tests/test_feedback.py` die bestehende `_note()`-Funktionssignatur und ihren Rückgabewert:

```python
def _note(
    index: int,
    missed: bool = False,
    cents_classification: str = "green",
    cents_value: float | None = 0.0,
    timing_classification: str = "on_time",
    timing_deviation_ms: float | None = None,
    stability_flag: bool = False,
    drift_flag: bool = False,
    drift_direction: str | None = None,
    sung_t: float | None = None,
) -> dict:
    return {
        "index": index,
        "start_t": index * 1.0,
        "end_t": index * 1.0 + 1.0,
        "target_hz": 440.0,
        "target_midi_note": 69,
        "missed": missed,
        "coverage_fraction": 0.0 if missed else 1.0,
        "cents_deviation": {"value": cents_value, "classification": cents_classification},
        "timing": {"deviation_ms": timing_deviation_ms, "classification": timing_classification},
        "held": False,
        "stability": {"applicable": True, "mad_cents": 0.0, "flag": stability_flag},
        "phrase_end_drift": {
            "applicable": True,
            "drift_cents": 0.0,
            "flag": drift_flag,
            "direction": drift_direction,
        },
        "sung_t": sung_t,
    }
```

- [ ] **Step 7: Failing-Tests für die `prompt.py`-Durchreichung schreiben**

Füge am Ende von `tests/test_feedback.py`s bestehendem `prompt.py`-Testblock (nach `test_build_prompt_context_samples_evenly_across_the_whole_song_when_capped`) an:

```python
def test_build_prompt_context_carries_sung_t_through():
    notes = [_note(0, missed=True, sung_t=12.5)]
    context = build_prompt_context(_score_result(notes))
    assert context["flagged_notes"][0]["sung_t"] == 12.5


def test_build_prompt_context_flagged_note_sung_t_can_be_none():
    notes = [_note(0, missed=True, sung_t=None)]
    context = build_prompt_context(_score_result(notes))
    assert context["flagged_notes"][0]["sung_t"] is None
```

- [ ] **Step 8: Test ausführen, Fehlschlag bestätigen**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/test_feedback.py -v -k sung_t`
Expected: die 2 neuen Tests FAIL — `KeyError: 'sung_t'` (in `build_prompt_context`s Rückgabe).

- [ ] **Step 9: `sung_t` in `build_prompt_context()` durchreichen**

In `backend/feedback/prompt.py`, im `flagged_notes.append({...})`-Block (nach der bestehenden Zeile `"phrase_end_drift_direction": note["phrase_end_drift"]["direction"],`, vor der schließenden `})`), ergänze:

```python
                "sung_t": note["sung_t"],
```

- [ ] **Step 10: Alle Tests ausführen, Erfolg bestätigen**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/ -q`
Expected: PASS, alle Tests grün (73 bisherige + 2 neue in `test_scoring.py` + 2 neue in `test_feedback.py` = 77).

- [ ] **Step 11: Commit**

```bash
git add backend/scoring/score.py backend/feedback/prompt.py tests/test_scoring.py tests/test_feedback.py
git commit -m "feat: compute each note's position in the sung recording and carry it through the feedback prompt context"
```

---

### Task 2: Kategorie-Zuordnung + `jump_to_t` in der `/api/feedback`-Antwort

**Files:**
- Modify: `backend/feedback/generate.py`
- Modify: `tests/test_feedback.py`

**Interfaces:**
- Consumes: `context["flagged_notes"][i]["sung_t"]` (Task 1); `build_prompt_context` (bereits vorhanden).
- Produces: jeder Punkt in `generate_feedback(...)["points"]` bekommt ein neues Feld `"jump_to_t": float | None`.

- [ ] **Step 1: Bestehenden Test an das neue Feld anpassen**

Der bestehende Test `test_generate_feedback_enriches_points_with_catalog_text` in `tests/test_feedback.py` erwartet aktuell ein Dict ohne `jump_to_t`. Ändere seinen `assert`-Block (das erwartete Dict in der Liste) von:

```python
    assert result["points"] == [{
        "problem": "Timing daneben",
        "technik": expected_entry["technik"],
        "uebung": expected_entry["uebung"],
        "wiederholungsaufgabe": None,
    }]
```

zu:

```python
    assert result["points"] == [{
        "problem": "Timing daneben",
        "technik": expected_entry["technik"],
        "uebung": expected_entry["uebung"],
        "wiederholungsaufgabe": None,
        "jump_to_t": None,
    }]
```

(Die in diesem Test verwendete `_score_result_with_tags(["timingprobleme"])`-Note hat `timing_classification="on_time"` — der Default von `_note()` — trifft also keinen `timingprobleme`-Matcher, deshalb bleibt `jump_to_t` hier `None`.)

- [ ] **Step 2: Failing-Tests für die Kategorie-Zuordnung schreiben**

Füge am Ende von `tests/test_feedback.py` an:

```python
def test_generate_feedback_includes_jump_to_t_from_first_matching_note(monkeypatch):
    monkeypatch.setattr("backend.feedback.generate.ANTHROPIC_API_KEY", "dummy-key")
    notes = [
        _note(0, timing_classification="too_late", timing_deviation_ms=100.0, sung_t=5.0),
        _note(1, timing_classification="too_late", timing_deviation_ms=120.0, sung_t=9.0),
    ]
    score_result = _score_result(notes)
    score_result["summary"]["problem_tags"] = ["timingprobleme"]
    fake = _FakeMessagesClient(points=[{"problem": "Timing", "uebung_id": "timingprobleme"}])
    result = generate_feedback(score_result, messages_client_factory=lambda: fake)
    assert result["points"][0]["jump_to_t"] == 5.0


def test_generate_feedback_skips_notes_without_sung_t_when_finding_jump_target(monkeypatch):
    monkeypatch.setattr("backend.feedback.generate.ANTHROPIC_API_KEY", "dummy-key")
    notes = [
        _note(0, missed=True, sung_t=None),
        _note(1, missed=True, sung_t=7.5),
    ]
    score_result = _score_result(notes)
    score_result["summary"]["problem_tags"] = ["unsaubere_einsaetze"]
    fake = _FakeMessagesClient(points=[{"problem": "Verfehlt", "uebung_id": "unsaubere_einsaetze"}])
    result = generate_feedback(score_result, messages_client_factory=lambda: fake)
    assert result["points"][0]["jump_to_t"] == 7.5


def test_generate_feedback_gives_different_notes_to_two_points_of_the_same_category(monkeypatch):
    monkeypatch.setattr("backend.feedback.generate.ANTHROPIC_API_KEY", "dummy-key")
    notes = [
        _note(0, stability_flag=True, sung_t=1.0),
        _note(1, stability_flag=True, sung_t=2.0),
    ]
    score_result = _score_result(notes)
    score_result["summary"]["problem_tags"] = ["instabile_lange_toene"]
    fake = _FakeMessagesClient(points=[
        {"problem": "A", "uebung_id": "instabile_lange_toene"},
        {"problem": "B", "uebung_id": "instabile_lange_toene"},
    ])
    result = generate_feedback(score_result, messages_client_factory=lambda: fake)
    assert result["points"][0]["jump_to_t"] == 1.0
    assert result["points"][1]["jump_to_t"] == 2.0


def test_generate_feedback_jump_to_t_is_none_when_no_note_matches(monkeypatch):
    monkeypatch.setattr("backend.feedback.generate.ANTHROPIC_API_KEY", "dummy-key")
    notes = [_note(0, missed=True, sung_t=3.0)]
    score_result = _score_result(notes)
    score_result["summary"]["problem_tags"] = ["absinkende_phrasenenden"]
    fake = _FakeMessagesClient(points=[{"problem": "X", "uebung_id": "absinkende_phrasenenden"}])
    result = generate_feedback(score_result, messages_client_factory=lambda: fake)
    assert result["points"][0]["jump_to_t"] is None
```

- [ ] **Step 3: Tests ausführen, Fehlschlag bestätigen**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/test_feedback.py -v -k "jump_to_t or enriches_points"`
Expected: FAIL — `KeyError: 'jump_to_t'` (`generate_feedback()` liefert das Feld noch nicht).

- [ ] **Step 4: Kategorie-Zuordnung in `generate.py` implementieren**

Kein neuer Import nötig — `backend/feedback/generate.py` importiert `Callable` bereits (`from typing import Any, Callable`).

Füge nach der bestehenden `_UNAVAILABLE_MESSAGE`-Zeile (vor `def generate_feedback(...)`) an:

```python
def _matches_timing(note: dict) -> bool:
    return note["timing_classification"] != "on_time"


def _matches_drift(note: dict) -> bool:
    return note["phrase_end_drift_flag"]


def _matches_stability(note: dict) -> bool:
    return note["stability_flag"]


def _matches_missed(note: dict) -> bool:
    return note["missed"] or note["cents_classification"] == "red"


# Bildet dieselbe Bedeutung wie die _PROBLEM_TAG_*-Konstanten in scoring/score.py ab:
# welches Feld einer geflaggten Note (siehe prompt.py::build_prompt_context) macht sie
# zu einem Kandidaten fuer die jeweilige Katalog-Kategorie. "haeufiges_hineingleiten"
# hat bewusst keinen Matcher - Glide-Erkennung ist noch nicht gebaut, problem_tags
# enthaelt diesen Wert nie, also kommt uebung_id dafuer auch nie vor generate_feedback an.
_CATEGORY_MATCHERS: dict[str, Callable[[dict], bool]] = {
    "timingprobleme": _matches_timing,
    "absinkende_phrasenenden": _matches_drift,
    "instabile_lange_toene": _matches_stability,
    "unsaubere_einsaetze": _matches_missed,
}


def _find_jump_to_t(flagged_notes: list[dict], uebung_id: str, used_notes: set[int]) -> float | None:
    """Sucht die erste Note in flagged_notes, die zur Kategorie uebung_id passt, eine
    Zeitstelle (sung_t) hat und noch nicht von einem frueheren Punkt derselben Antwort
    verwendet wurde (used_notes, ueber die gesamte Punkt-Verarbeitungsschleife hinweg
    gefuehrt) - damit bei mehreren Punkten derselben Kategorie nicht alle zur gleichen
    Stelle springen. Markiert die gefundene Note als verbraucht. flagged_notes ist
    dieselbe (ggf. bei >150 Eintraegen gleichmaessig ausgeduennte) Liste, die auch den
    Claude-Prompt gespeist hat - die Zeitstelle bleibt also konsistent mit dem, was
    Claude tatsaechlich gesehen hat."""
    matcher = _CATEGORY_MATCHERS.get(uebung_id)
    if matcher is None:
        return None
    for note in flagged_notes:
        if note["index"] in used_notes:
            continue
        if note["sung_t"] is None:
            continue
        if matcher(note):
            used_notes.add(note["index"])
            return note["sung_t"]
    return None
```

- [ ] **Step 5: `jump_to_t` in `generate_feedback()`s Punkt-Aufbau ergänzen**

Ersetze in `backend/feedback/generate.py` den Docstring von `generate_feedback` von:

```python
    """Liefert {"points": [...]} mit bis zu 3 Punkten (problem, technik, uebung,
    wiederholungsaufgabe). Leere Liste, wenn score_result["summary"]["problem_tags"]
    leer ist (kein API-Aufruf noetig). Wirft FeedbackUnavailableError, wenn der
    API-Key fehlt oder der Anthropic-Aufruf fehlschlaegt. messages_client_factory
    ist injizierbar fuer Tests (siehe test_feedback.py) - Default baut einen echten
    anthropic.Anthropic-Client."""
```

zu:

```python
    """Liefert {"points": [...]} mit bis zu 3 Punkten (problem, technik, uebung,
    wiederholungsaufgabe, jump_to_t). Leere Liste, wenn score_result["summary"]
    ["problem_tags"] leer ist (kein API-Aufruf noetig). Wirft FeedbackUnavailableError,
    wenn der API-Key fehlt oder der Anthropic-Aufruf fehlschlaegt. jump_to_t ist die
    Position (Sekunden) in der eigenen Aufnahme der ersten unverbrauchten Note dieser
    Kategorie mit Zeitstelle, oder None. messages_client_factory ist injizierbar fuer
    Tests (siehe test_feedback.py) - Default baut einen echten anthropic.Anthropic-
    Client."""
```

Ersetze den Punkt-Aufbau-Block am Ende der Funktion von:

```python
    points = []
    for raw in raw_points[:3]:
        entry = lookup(catalog, raw.get("uebung_id", ""))
        if entry is None:
            continue
        points.append({
            "problem": raw.get("problem") or entry["problem"],
            "technik": entry["technik"],
            "uebung": entry["uebung"],
            "wiederholungsaufgabe": raw.get("wiederholungsaufgabe"),
        })
    return {"points": points}
```

zu:

```python
    used_notes: set[int] = set()
    points = []
    for raw in raw_points[:3]:
        entry = lookup(catalog, raw.get("uebung_id", ""))
        if entry is None:
            continue
        uebung_id = raw.get("uebung_id", "")
        points.append({
            "problem": raw.get("problem") or entry["problem"],
            "technik": entry["technik"],
            "uebung": entry["uebung"],
            "wiederholungsaufgabe": raw.get("wiederholungsaufgabe"),
            "jump_to_t": _find_jump_to_t(context["flagged_notes"], uebung_id, used_notes),
        })
    return {"points": points}
```

- [ ] **Step 6: Alle Tests ausführen, Erfolg bestätigen**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/ -q`
Expected: PASS, alle Tests grün.

- [ ] **Step 7: Commit**

```bash
git add backend/feedback/generate.py tests/test_feedback.py
git commit -m "feat: map each feedback point to the first matching, unused note's position in the recording"
```

---

### Task 3: `SessionState`-Player-Zentralisierung + `PlaybackButton`-Umbau

**Files:**
- Modify: `mobile/lib/state/session_state.dart`
- Modify: `mobile/lib/widgets/playback_button.dart`
- Modify: `mobile/test/playback_button_test.dart`
- Modify: `mobile/test/playback_button_layout_test.dart`

**Interfaces:**
- Consumes: nichts Neues aus Task 1/2 (rein mobile-seitig, unabhängig vom Backend-Teil).
- Produces:
  - `AudioPlaybackController` (Interface, jetzt in `session_state.dart` definiert statt `playback_button.dart`): `play(Uint8List)`, `playFrom(Uint8List, Duration)`, `pause()`, `stop()`, `onComplete`-Stream, `dispose()`.
  - `SessionState`: neuer optionaler Konstruktor-Parameter `AudioPlaybackController Function()? playbackControllerFactory`; neue Felder `bool isPlaying`; neue Methoden `Future<void> play(Uint8List bytes)`, `Future<void> playFrom(Uint8List bytes, Duration position)`, `Future<void> pause()`, `Future<void> stop()`, `bool isPlayingAudio(Uint8List? bytes)`; überschreibt `dispose()`.
  - `PlaybackButton` verliert seinen `controllerFactory`-Parameter vollständig (Breaking Change fuer bestehende Aufrufer — betrifft nur die beiden Testdateien in diesem Task, `home_screen.dart` übergibt `controllerFactory` bereits heute nicht).

**Wichtig:** der Audio-Player wird **lazy** (erst beim ersten `play`/`playFrom`/`pause`/`stop`-Aufruf) konstruiert, nicht im `SessionState`-Konstruktor selbst. Ohne diese Absicherung würde jeder der ~50 bestehenden Tests, die irgendwo eine `SessionState` bauen (auch völlig unabhängig von Wiedergabe), einen echten `AudioPlayer()` samt unawaited Plattform-Kanal-Aufrufen anstoßen — mit Risiko auf Test-Rauschen. Kein bestehender Test außerhalb der beiden hier modifizierten Dateien ruft `play`/`pause`/`playFrom` auf, ist also von dieser Änderung nicht betroffen.

- [ ] **Step 1: `AudioPlaybackController` + `_RealAudioPlaybackController` in `session_state.dart` verschieben und um `playFrom` erweitern**

Ergänze den Import-Block von `mobile/lib/state/session_state.dart` (nach `import 'package:flutter/foundation.dart';`):

```dart
import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
```

Füge direkt vor der `class SessionState extends ChangeNotifier {`-Zeile an (nach den bestehenden `enum`-Deklarationen):

```dart
/// Duenne Abstraktion ueber die Audio-Wiedergabe, injizierbar fuer Tests. Lebt hier
/// (nicht mehr in playback_button.dart), weil SessionState jetzt den einen zentralen
/// Player fuer die ganze App besitzt - PlaybackButton und die Feedback-Sprungbuttons
/// teilen sich ihn, damit nie zwei Wiedergaben gleichzeitig laufen.
abstract class AudioPlaybackController {
  Future<void> play(Uint8List bytes);
  Future<void> playFrom(Uint8List bytes, Duration position);
  Future<void> pause();
  Future<void> stop();
  Stream<void> get onComplete;
  void dispose();
}

/// Standardimplementierung, delegiert an das echte audioplayers-Paket.
class _RealAudioPlaybackController implements AudioPlaybackController {
  final AudioPlayer _player = AudioPlayer();

  @override
  Future<void> play(Uint8List bytes) => _player.play(BytesSource(bytes));

  @override
  Future<void> playFrom(Uint8List bytes, Duration position) =>
      _player.play(BytesSource(bytes), position: position);

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() => _player.stop();

  @override
  Stream<void> get onComplete => _player.onPlayerComplete;

  @override
  void dispose() {
    unawaited(_player.dispose());
  }
}
```

- [ ] **Step 2: `SessionState`-Konstruktor um `playbackControllerFactory` erweitern**

Ersetze in `mobile/lib/state/session_state.dart` den bestehenden Konstruktor-Block:

```dart
  final MidiApi midiApi;
  final AudioApi audioApi;
  final SyncApi syncApi;
  final ScoreApi scoreApi;
  final FeedbackApi feedbackApi;

  SessionState({
    required this.midiApi,
    required this.audioApi,
    required this.syncApi,
    required this.scoreApi,
    required this.feedbackApi,
  });
```

durch:

```dart
  final MidiApi midiApi;
  final AudioApi audioApi;
  final SyncApi syncApi;
  final ScoreApi scoreApi;
  final FeedbackApi feedbackApi;
  final AudioPlaybackController Function() _playbackControllerFactory;

  SessionState({
    required this.midiApi,
    required this.audioApi,
    required this.syncApi,
    required this.scoreApi,
    required this.feedbackApi,
    AudioPlaybackController Function()? playbackControllerFactory,
  }) : _playbackControllerFactory =
            playbackControllerFactory ?? (() => _RealAudioPlaybackController());

  AudioPlaybackController? _playbackControllerInstance;
  StreamSubscription<void>? _playbackCompleteSubscription;
  bool isPlaying = false;
  Uint8List? _playingBytes;
  Object? _playbackGeneration;

  /// Baut den Player erst beim ersten tatsaechlichen Gebrauch (nicht im Konstruktor) -
  /// sonst wuerde jeder Test, der irgendwo eine SessionState baut, unabhaengig davon ob
  /// er Wiedergabe ueberhaupt testet, einen echten AudioPlayer() samt unawaited
  /// Plattform-Kanal-Aufrufen anstossen.
  AudioPlaybackController get _playbackController {
    var instance = _playbackControllerInstance;
    if (instance == null) {
      instance = _playbackControllerFactory();
      _playbackControllerInstance = instance;
      _playbackCompleteSubscription = instance.onComplete.listen((_) {
        isPlaying = false;
        notifyListeners();
      });
    }
    return instance;
  }

  /// Ob genau diese Bytes (Objekt-Identitaet - reicht, da sungAudioBytes/
  /// referenceAudioBytes stabile Referenzen sind, die nicht bei jedem Rebuild neu
  /// erzeugt werden) gerade abgespielt werden. Damit koennen mehrere PlaybackButton-
  /// Instanzen (Referenz- und Gesangsaufnahme) trotz gemeinsamem Player weiterhin
  /// unabhaengig ihren eigenen Play/Pause-Icon-Status anzeigen.
  bool isPlayingAudio(Uint8List? bytes) =>
      isPlaying && bytes != null && identical(_playingBytes, bytes);

  Future<void> play(Uint8List bytes) async {
    final generation = _playbackGeneration = Object();
    _playingBytes = bytes;
    await _playbackController.play(bytes);
    if (generation != _playbackGeneration) return;
    isPlaying = true;
    notifyListeners();
  }

  Future<void> playFrom(Uint8List bytes, Duration position) async {
    final generation = _playbackGeneration = Object();
    _playingBytes = bytes;
    await _playbackController.playFrom(bytes, position);
    if (generation != _playbackGeneration) return;
    isPlaying = true;
    notifyListeners();
  }

  Future<void> pause() async {
    final generation = _playbackGeneration = Object();
    await _playbackController.pause();
    if (generation != _playbackGeneration) return;
    isPlaying = false;
    notifyListeners();
  }

  Future<void> stop() async {
    final generation = _playbackGeneration = Object();
    await _playbackController.stop();
    if (generation != _playbackGeneration) return;
    isPlaying = false;
    _playingBytes = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _playbackCompleteSubscription?.cancel();
    _playbackControllerInstance?.dispose();
    super.dispose();
  }
```

- [ ] **Step 3: `flutter analyze` gegen `session_state.dart` prüfen**

Run: `cd mobile && flutter analyze lib/state/session_state.dart`
Expected: keine Fehler (rein statische Prüfung an dieser Stelle — `play()`/`pause()` und damit auch die lazy Konstruktion/den Generation-Token werden bereits in diesem Task über `PlaybackButton`s Tests (Steps 5-6) mitgetestet, `playFrom()` folgt in Task 5 zusammen mit dem Sprung-Button, seinem ersten echten Verbraucher).

- [ ] **Step 4: `playback_button.dart` umbauen**

Ersetze den kompletten Inhalt von `mobile/lib/widgets/playback_button.dart` durch:

```dart
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/session_state.dart';

/// Spielt eine bereits hochgeladene Aufnahme erneut ab (im Gegensatz zu
/// RecordingControls Vorschau, die nur *vor* dem Hochladen existiert). Rendert
/// nichts, solange keine Bytes vorliegen. Delegiert Wiedergabe/Pause an
/// SessionState (siehe AudioPlaybackController dort) - der Play/Pause-Status
/// kommt aus session.isPlayingAudio(audioBytes), damit mehrere PlaybackButton-
/// Instanzen (Referenz-/Gesangsaufnahme) trotz gemeinsamem Player unabhaengig
/// ihren eigenen Status zeigen. Gleiches _isBusy-Guard-Muster wie
/// RecordingControl, um dieselbe Await-Race-Klasse zu vermeiden.
class PlaybackButton extends StatefulWidget {
  final Uint8List? audioBytes;

  const PlaybackButton({super.key, required this.audioBytes});

  @override
  State<PlaybackButton> createState() => _PlaybackButtonState();
}

class _PlaybackButtonState extends State<PlaybackButton> {
  bool _isBusy = false;
  String? _errorMessage;
  Object? _playbackToken;

  @override
  void didUpdateWidget(covariant PlaybackButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.audioBytes != oldWidget.audioBytes) {
      _errorMessage = null;
      _playbackToken = Object();
      final session = context.read<SessionState>();
      if (session.isPlayingAudio(oldWidget.audioBytes)) {
        unawaited(session.stop());
      }
    }
  }

  Future<void> _togglePlayback(SessionState session) async {
    if (_isBusy || widget.audioBytes == null) return;
    setState(() => _isBusy = true);
    final token = _playbackToken;
    try {
      if (session.isPlayingAudio(widget.audioBytes)) {
        await session.pause();
      } else {
        await session.play(widget.audioBytes!);
      }
    } catch (e) {
      if (!mounted || token != _playbackToken) return;
      setState(() => _errorMessage = 'Wiedergabe fehlgeschlagen: $e');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionState>();
    if (widget.audioBytes == null) return const SizedBox.shrink();
    final isThisPlaying = session.isPlayingAudio(widget.audioBytes);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IconButton(
          onPressed: _isBusy ? null : () => _togglePlayback(session),
          icon: Icon(isThisPlaying ? Icons.pause : Icons.play_arrow),
          tooltip: isThisPlaying ? 'Pause' : 'Erneut abspielen',
        ),
        if (_errorMessage != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              _errorMessage!,
              style: TextStyle(color: Colors.red.shade300, fontSize: 12),
            ),
          ),
      ],
    );
  }
}
```

- [ ] **Step 5: `playback_button_test.dart` auf die neue Delegation umstellen**

Ersetze den kompletten Inhalt von `mobile/test/playback_button_test.dart` durch:

```dart
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:singing_feedback_mobile/api/api_client.dart';
import 'package:singing_feedback_mobile/api/audio_api.dart';
import 'package:singing_feedback_mobile/api/feedback_api.dart';
import 'package:singing_feedback_mobile/api/midi_api.dart';
import 'package:singing_feedback_mobile/api/score_api.dart';
import 'package:singing_feedback_mobile/api/sync_api.dart';
import 'package:singing_feedback_mobile/state/session_state.dart';
import 'package:singing_feedback_mobile/widgets/playback_button.dart';

/// Fake-Implementierung von [AudioPlaybackController] fuer Tests, ganz ohne
/// echten Plattform-Kanal. [play]/[pause] koennen ueber die Completer auf
/// "haengend" gehalten werden, um Await-Race-Szenarien simulieren zu koennen,
/// und optional einen Fehler werfen.
class _FakePlaybackController implements AudioPlaybackController {
  Completer<void>? playCompleter;
  Completer<void>? pauseCompleter;
  Object? throwOnPlay;
  Object? throwOnPause;
  int playCallCount = 0;
  int playFromCallCount = 0;
  int pauseCallCount = 0;
  int stopCallCount = 0;
  int disposeCallCount = 0;
  final _completeController = StreamController<void>.broadcast();

  @override
  Future<void> play(Uint8List bytes) async {
    playCallCount++;
    if (playCompleter != null) {
      await playCompleter!.future;
    }
    if (throwOnPlay != null) throw throwOnPlay!;
  }

  @override
  Future<void> playFrom(Uint8List bytes, Duration position) async {
    playFromCallCount++;
  }

  @override
  Future<void> pause() async {
    pauseCallCount++;
    if (pauseCompleter != null) {
      await pauseCompleter!.future;
    }
    if (throwOnPause != null) throw throwOnPause!;
  }

  @override
  Future<void> stop() async {
    stopCallCount++;
  }

  @override
  Stream<void> get onComplete => _completeController.stream;

  @override
  void dispose() {
    disposeCallCount++;
    unawaited(_completeController.close());
  }
}

SessionState _buildSession(AudioPlaybackController fake) {
  final client = ApiClient(baseUrl: 'http://fake.local');
  return SessionState(
    midiApi: MidiApi(client),
    audioApi: AudioApi(client),
    syncApi: SyncApi(client),
    scoreApi: ScoreApi(client),
    feedbackApi: FeedbackApi(client),
    playbackControllerFactory: () => fake,
  );
}

Widget _wrap(SessionState session, Widget child) {
  return ChangeNotifierProvider<SessionState>.value(
    value: session,
    child: MaterialApp(home: Scaffold(body: child)),
  );
}

void main() {
  group('PlaybackButton Zustandsautomat (_togglePlayback)', () {
    testWidgets('Play-Tap wechselt Icon von Play zu Pause', (tester) async {
      final fake = _FakePlaybackController();
      final session = _buildSession(fake);
      final bytes = Uint8List.fromList([1, 2, 3]);

      await tester.pumpWidget(_wrap(session, PlaybackButton(audioBytes: bytes)));

      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      expect(find.byIcon(Icons.pause), findsNothing);

      await tester.tap(find.byIcon(Icons.play_arrow));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.pause), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow), findsNothing);
      expect(fake.playCallCount, 1);
    });

    testWidgets(
        'kein setState-Fehler, wenn das Widget waehrend eines ausstehenden play() '
        'unmounted wird', (tester) async {
      final fake = _FakePlaybackController()..playCompleter = Completer<void>();
      final session = _buildSession(fake);
      final bytes = Uint8List.fromList([1, 2, 3]);

      await tester.pumpWidget(_wrap(session, PlaybackButton(audioBytes: bytes)));

      await tester.tap(find.byIcon(Icons.play_arrow));
      await tester.pump(); // startet _togglePlayback, haengt in await session.play()

      await tester.pumpWidget(_wrap(session, const SizedBox.shrink()));

      fake.playCompleter!.complete();
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'kein setState-Fehler, wenn play() erst nach dem Unmount fehlschlaegt',
        (tester) async {
      final fake = _FakePlaybackController()..playCompleter = Completer<void>();
      final session = _buildSession(fake);
      final bytes = Uint8List.fromList([1, 2, 3]);

      await tester.pumpWidget(_wrap(session, PlaybackButton(audioBytes: bytes)));

      await tester.tap(find.byIcon(Icons.play_arrow));
      await tester.pump();

      await tester.pumpWidget(_wrap(session, const SizedBox.shrink()));

      fake.playCompleter!.completeError(Exception('Geraetefehler'));
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'Busy-Guard verhindert einen zweiten Play-Aufruf, waehrend der erste '
        'noch laeuft (Doppel-Tap)', (tester) async {
      final fake = _FakePlaybackController()..playCompleter = Completer<void>();
      final session = _buildSession(fake);
      final bytes = Uint8List.fromList([1, 2, 3]);

      await tester.pumpWidget(_wrap(session, PlaybackButton(audioBytes: bytes)));

      await tester.tap(find.byIcon(Icons.play_arrow));
      await tester.pump();

      final button = tester.widget<IconButton>(find.byType(IconButton));
      expect(button.onPressed, isNull);

      await tester.tap(find.byIcon(Icons.play_arrow));
      await tester.pump();

      expect(fake.playCallCount, 1);

      fake.playCompleter!.complete();
      await tester.pump();
      await tester.pump();

      expect(fake.playCallCount, 1);
    });

    testWidgets(
        'zwei PlaybackButton-Instanzen mit unterschiedlichen Bytes zeigen '
        'unabhaengige Play/Pause-Icons (geteilter Player)', (tester) async {
      final fake = _FakePlaybackController();
      final session = _buildSession(fake);
      final bytesA = Uint8List.fromList([1, 2, 3]);
      final bytesB = Uint8List.fromList([4, 5, 6]);

      await tester.pumpWidget(_wrap(
        session,
        Column(children: [
          PlaybackButton(audioBytes: bytesA),
          PlaybackButton(audioBytes: bytesB),
        ]),
      ));

      await tester.tap(find.byIcon(Icons.play_arrow).first);
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.pause), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    });
  });
}
```

- [ ] **Step 6: `playback_button_layout_test.dart` auf die neue Delegation umstellen**

Ersetze den kompletten Inhalt von `mobile/test/playback_button_layout_test.dart` durch:

```dart
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:singing_feedback_mobile/api/api_client.dart';
import 'package:singing_feedback_mobile/api/audio_api.dart';
import 'package:singing_feedback_mobile/api/feedback_api.dart';
import 'package:singing_feedback_mobile/api/midi_api.dart';
import 'package:singing_feedback_mobile/api/score_api.dart';
import 'package:singing_feedback_mobile/api/sync_api.dart';
import 'package:singing_feedback_mobile/state/session_state.dart';
import 'package:singing_feedback_mobile/widgets/playback_button.dart';

class _FakePlaybackController implements AudioPlaybackController {
  Object? throwOnPlay;

  @override
  Future<void> play(Uint8List bytes) async {
    if (throwOnPlay != null) throw throwOnPlay!;
  }

  @override
  Future<void> playFrom(Uint8List bytes, Duration position) async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  Stream<void> get onComplete => const Stream.empty();

  @override
  void dispose() {}
}

SessionState _buildSession(AudioPlaybackController fake) {
  final client = ApiClient(baseUrl: 'http://fake.local');
  return SessionState(
    midiApi: MidiApi(client),
    audioApi: AudioApi(client),
    syncApi: SyncApi(client),
    scoreApi: ScoreApi(client),
    feedbackApi: FeedbackApi(client),
    playbackControllerFactory: () => fake,
  );
}

/// Baut dieselbe Row-Struktur wie home_screen.dart: StatusBanner-Ersatz in
/// Expanded, PlaybackButton in einer ConstrainedBox (maxWidth: 180).
Widget _rowUnderTest(
  SessionState session, {
  required Widget statusChild,
  required Widget playbackButton,
}) {
  return ChangeNotifierProvider<SessionState>.value(
    value: session,
    child: MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 390, // realistische Telefonbreite, siehe vorherige Reviews
          child: Row(
            children: [
              Expanded(child: statusChild),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 180),
                child: playbackButton,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('PlaybackButton Layout', () {
    testWidgets(
        'lange, realistische Fehlermeldung fuehrt bei 390dp Breite zu keinem '
        'RenderFlex-Overflow', (tester) async {
      final fake = _FakePlaybackController()
        ..throwOnPlay = Exception(
          'Der Audio-Codec wird auf diesem Geraet nicht unterstuetzt und die '
          'Wiedergabe konnte nicht gestartet werden.',
        );
      final session = _buildSession(fake);
      final bytes = Uint8List.fromList([1, 2, 3]);

      await tester.pumpWidget(
        _rowUnderTest(
          session,
          statusChild: const Text('Status: bereit'),
          playbackButton: PlaybackButton(audioBytes: bytes),
        ),
      );

      await tester.tap(find.byIcon(Icons.play_arrow));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.textContaining('Wiedergabe fehlgeschlagen'), findsOneWidget);
    });

    testWidgets(
        'StatusBanner-Ersatz (Expanded) bekommt bei fehlerfreiem PlaybackButton '
        'die volle verbleibende Breite statt eines erzwungenen 50/50-Splits',
        (tester) async {
      final fake = _FakePlaybackController();
      final session = _buildSession(fake);
      final bytes = Uint8List.fromList([1, 2, 3]);
      const statusKey = Key('status');

      await tester.pumpWidget(
        _rowUnderTest(
          session,
          statusChild: const SizedBox(
            key: statusKey,
            height: 20,
            child: Text('Status: bereit, alles im gruenen Bereich'),
          ),
          playbackButton: PlaybackButton(audioBytes: bytes),
        ),
      );
      await tester.pumpAndSettle();

      final statusWidth = tester.getSize(find.byKey(statusKey)).width;
      expect(statusWidth, greaterThan(300));
    });
  });
}
```

- [ ] **Step 7: Tests ausführen, Erfolg bestätigen**

Run: `cd mobile && flutter test test/playback_button_test.dart test/playback_button_layout_test.dart`
Expected: PASS, alle Tests grün (5 in `playback_button_test.dart`, 2 in `playback_button_layout_test.dart`).

- [ ] **Step 8: Vollen Test-Suite-Lauf und Analyse verifizieren**

Run: `cd mobile && flutter test -j 1`
Expected: alle Tests grün, keine Regression in bestehenden, nicht direkt geänderten Testdateien (z.B. `session_state_test.dart`, `feedback_section_test.dart` — keine dieser Dateien ruft `play`/`pause`/`playFrom` auf, ist also von der Lazy-Konstruktion nicht betroffen).

Run: `cd mobile && flutter analyze`
Expected: keine Fehler/Warnungen.

- [ ] **Step 9: Commit**

```bash
git add mobile/lib/state/session_state.dart mobile/lib/widgets/playback_button.dart mobile/test/playback_button_test.dart mobile/test/playback_button_layout_test.dart
git commit -m "refactor: centralize audio playback in SessionState, PlaybackButton delegates"
```

---

### Task 4: Mobile Wire-Format — `ScoreNote.sungT` + `FeedbackPoint.jumpToT`

**Files:**
- Modify: `mobile/lib/models/score_result.dart`
- Modify: `mobile/lib/models/feedback_result.dart`
- Modify: `mobile/test/score_result_test.dart`

**Interfaces:**
- Consumes: `sung_t`/`jump_to_t` JSON-Felder (Task 1, Task 2).
- Produces: `ScoreNote.sungT` (`double?`, mit `fromJson`/`toJson`); `FeedbackPoint.jumpToT` (`double?`, mit `fromJson`).

**Wichtig:** `SessionState.requestFeedback()` schickt `scoreResult!.toJson()` an `/api/feedback` — ohne `sungT` in `ScoreNote.toJson()` würde das Backend nie ein `sung_t` sehen, selbst wenn `/api/score` es korrekt geliefert hat. Ohne diesen Task bleibt `jump_to_t` in der Praxis immer `null`.

- [ ] **Step 1: Failing-Test für `ScoreNote.sungT` erweitern**

Ändere in `mobile/test/score_result_test.dart` die `_noteJson()`-Funktion von:

```dart
Map<String, dynamic> _noteJson() => {
      'index': 0, 'start_t': 0.0, 'end_t': 1.0,
      'target_hz': 440.0, 'target_midi_note': 69,
      'missed': false, 'coverage_fraction': 1.0,
      'cents_deviation': {'value': 1.2, 'classification': 'green'},
      'timing': {'deviation_ms': 4.0, 'classification': 'on_time'},
      'held': true,
      'stability': {'applicable': true, 'mad_cents': 0.8, 'flag': false},
      'phrase_end_drift': {'applicable': true, 'drift_cents': 0.3, 'flag': false, 'direction': null},
    };
```

zu:

```dart
Map<String, dynamic> _noteJson() => {
      'index': 0, 'start_t': 0.0, 'end_t': 1.0,
      'target_hz': 440.0, 'target_midi_note': 69,
      'missed': false, 'coverage_fraction': 1.0,
      'cents_deviation': {'value': 1.2, 'classification': 'green'},
      'timing': {'deviation_ms': 4.0, 'classification': 'on_time'},
      'held': true,
      'stability': {'applicable': true, 'mad_cents': 0.8, 'flag': false},
      'phrase_end_drift': {'applicable': true, 'drift_cents': 0.3, 'flag': false, 'direction': null},
      'sung_t': 0.12,
    };
```

(Der bestehende Round-Trip-Test `ScoreResult.toJson() ist die Umkehrung von ScoreResult.fromJson()` braucht keine weitere Änderung — er deckt das neue Feld automatisch mit ab, sobald `sung_t` im Fixture steht.)

- [ ] **Step 2: Test ausführen, Fehlschlag bestätigen**

Run: `cd mobile && flutter test test/score_result_test.dart`
Expected: FAIL — `toJson()`-Ergebnis enthält kein `sung_t`, der Round-Trip-Vergleich schlägt fehl.

- [ ] **Step 3: `sungT` in `ScoreNote` ergänzen**

In `mobile/lib/models/score_result.dart`, `class ScoreNote`: ergänze das Feld (nach der bestehenden Zeile `final String? driftDirection;`):

```dart
  final double? sungT;
```

Ergänze den Konstruktor-Parameter (nach `required this.driftDirection,`):

```dart
    required this.sungT,
```

Ergänze in `factory ScoreNote.fromJson(...)` (nach der bestehenden Zeile `driftDirection: drift['direction'] as String?,`):

```dart
      sungT: (json['sung_t'] as num?)?.toDouble(),
```

Ergänze in `Map<String, dynamic> toJson()` (nach der bestehenden Zeile `'phrase_end_drift': {...},` — direkt vor der schließenden `};`):

```dart
        'sung_t': sungT,
```

- [ ] **Step 4: Test ausführen, Erfolg bestätigen**

Run: `cd mobile && flutter test test/score_result_test.dart`
Expected: PASS.

- [ ] **Step 5: `jumpToT` in `FeedbackPoint` ergänzen**

In `mobile/lib/models/feedback_result.dart`, `class FeedbackPoint`: ergänze das Feld (nach `final String? wiederholungsaufgabe;`):

```dart
  final double? jumpToT;
```

Ergänze den Konstruktor-Parameter (nach `required this.wiederholungsaufgabe,`):

```dart
    required this.jumpToT,
```

Ergänze in `factory FeedbackPoint.fromJson(...)` (nach `wiederholungsaufgabe: json['wiederholungsaufgabe'] as String?,`):

```dart
        jumpToT: (json['jump_to_t'] as num?)?.toDouble(),
```

- [ ] **Step 6: Vollen Test-Suite-Lauf und Analyse verifizieren**

Run: `cd mobile && flutter test -j 1`
Expected: alle Tests grün. `feedback_section_test.dart`s bestehende 4 Tests bleiben unverändert grün, da ihr Fake-`feedbackResponse` kein `jump_to_t` mitschickt und `(json['jump_to_t'] as num?)` bei fehlendem Schlüssel einfach `null` liefert.

Run: `cd mobile && flutter analyze`
Expected: keine Fehler/Warnungen.

- [ ] **Step 7: Commit**

```bash
git add mobile/lib/models/score_result.dart mobile/lib/models/feedback_result.dart mobile/test/score_result_test.dart
git commit -m "feat: add sungT/jumpToT to the mobile ScoreNote/FeedbackPoint wire format"
```

---

### Task 5: Sprung-Button auf der Feedback-Karte

**Files:**
- Modify: `mobile/lib/widgets/feedback_section.dart`
- Modify: `mobile/test/feedback_section_test.dart`

**Interfaces:**
- Consumes: `SessionState.playFrom(Uint8List, Duration)`, `SessionState.sungAudioBytes` (Task 3); `FeedbackPoint.jumpToT` (Task 4).
- Produces: `_FeedbackPointCard` wird zu einem `StatefulWidget` mit eigenem Sprung-Button.

- [ ] **Step 1: Failing-Tests für den Sprung-Button schreiben**

Ergänze in `mobile/test/feedback_section_test.dart` den Import-Block (nach `import 'package:singing_feedback_mobile/api/feedback_api.dart';`):

```dart
import 'dart:typed_data';
```

(`dart:typed_data` wird für `Uint8List` in den neuen Tests gebraucht — `Uint8List` selbst wird bereits transitiv genutzt, aber der Test braucht jetzt eine eigene Variable dafür.)

Füge eine Fake-`AudioPlaybackController`-Klasse hinzu (nach der bestehenden `class _FakeApiClient extends ApiClient { ... }`):

```dart
class _FakePlaybackController implements AudioPlaybackController {
  int playFromCallCount = 0;
  Uint8List? lastPlayFromBytes;
  Duration? lastPlayFromPosition;

  @override
  Future<void> play(Uint8List bytes) async {}

  @override
  Future<void> playFrom(Uint8List bytes, Duration position) async {
    playFromCallCount++;
    lastPlayFromBytes = bytes;
    lastPlayFromPosition = position;
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  Stream<void> get onComplete => const Stream.empty();

  @override
  void dispose() {}
}
```

Ergänze den Import (nach `import 'package:singing_feedback_mobile/state/session_state.dart';` — `AudioPlaybackController` wird jetzt von dort exportiert, kein neuer Import-Pfad nötig, nur zur Orientierung).

Ändere `_buildSession()` von:

```dart
SessionState _buildSession(_FakeApiClient client) {
  return SessionState(
    midiApi: MidiApi(client),
    audioApi: AudioApi(client),
    syncApi: SyncApi(client),
    scoreApi: ScoreApi(client),
    feedbackApi: FeedbackApi(client),
  );
}
```

zu:

```dart
SessionState _buildSession(_FakeApiClient client, {AudioPlaybackController? fakePlayback}) {
  return SessionState(
    midiApi: MidiApi(client),
    audioApi: AudioApi(client),
    syncApi: SyncApi(client),
    scoreApi: ScoreApi(client),
    feedbackApi: FeedbackApi(client),
    playbackControllerFactory: fakePlayback == null ? null : () => fakePlayback,
  );
}
```

(Bestehende Aufrufe `_buildSession(...)` ohne zweites Argument bleiben unverändert gültig.)

Füge am Ende von `feedback_section_test.dart`s `group('FeedbackSection', ...)` an:

```dart
    testWidgets('Sprung-Button erscheint nur, wenn jumpToT gesetzt ist', (tester) async {
      final client = _FakeApiClient()
        ..feedbackResponse = {
          'feedback': {
            'points': [
              {
                'problem': 'Mit Zeitstelle',
                'technik': 'T1', 'uebung': 'U1',
                'wiederholungsaufgabe': null, 'jump_to_t': 5.0,
              },
              {
                'problem': 'Ohne Zeitstelle',
                'technik': 'T2', 'uebung': 'U2',
                'wiederholungsaufgabe': null, 'jump_to_t': null,
              },
            ],
          },
        };
      final session = _buildSession(client)
        ..scoreResult = _dummyScoreResult()
        ..sungAudioBytes = Uint8List.fromList([1, 2, 3]);
      await tester.pumpWidget(_wrap(session));

      await tester.tap(find.text('Feedback anfordern'));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);
    });

    testWidgets(
        'Tap auf den Sprung-Button spielt ab 0,5s vor der Zeitstelle ab',
        (tester) async {
      final fakePlayback = _FakePlaybackController();
      final client = _FakeApiClient()
        ..feedbackResponse = {
          'feedback': {
            'points': [
              {
                'problem': 'Timing daneben',
                'technik': 'T1', 'uebung': 'U1',
                'wiederholungsaufgabe': null, 'jump_to_t': 5.0,
              },
            ],
          },
        };
      final audioBytes = Uint8List.fromList([1, 2, 3]);
      final session = _buildSession(client, fakePlayback: fakePlayback)
        ..scoreResult = _dummyScoreResult()
        ..sungAudioBytes = audioBytes;
      await tester.pumpWidget(_wrap(session));

      await tester.tap(find.text('Feedback anfordern'));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.play_circle_outline));
      await tester.pumpAndSettle();

      expect(fakePlayback.playFromCallCount, 1);
      expect(fakePlayback.lastPlayFromBytes, same(audioBytes));
      expect(fakePlayback.lastPlayFromPosition, const Duration(milliseconds: 4500));
    });

    testWidgets(
        'Sprung bei einer Zeitstelle unter 0,5s startet bei 0 statt negativ',
        (tester) async {
      final fakePlayback = _FakePlaybackController();
      final client = _FakeApiClient()
        ..feedbackResponse = {
          'feedback': {
            'points': [
              {
                'problem': 'Ganz am Anfang',
                'technik': 'T1', 'uebung': 'U1',
                'wiederholungsaufgabe': null, 'jump_to_t': 0.2,
              },
            ],
          },
        };
      final audioBytes = Uint8List.fromList([1, 2, 3]);
      final session = _buildSession(client, fakePlayback: fakePlayback)
        ..scoreResult = _dummyScoreResult()
        ..sungAudioBytes = audioBytes;
      await tester.pumpWidget(_wrap(session));

      await tester.tap(find.text('Feedback anfordern'));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.play_circle_outline));
      await tester.pumpAndSettle();

      expect(fakePlayback.lastPlayFromPosition, Duration.zero);
    });
```

- [ ] **Step 2: Tests ausführen, Fehlschlag bestätigen**

Run: `cd mobile && flutter test test/feedback_section_test.dart`
Expected: die 3 neuen Tests FAIL — `find.byIcon(Icons.play_circle_outline)` findet nichts, `_FeedbackPointCard` hat noch keinen Sprung-Button.

- [ ] **Step 3: `_FeedbackPointCard` um Sprung-Button erweitern**

Ersetze in `mobile/lib/widgets/feedback_section.dart` die Zeile, die `_FeedbackPointCard` instanziiert:

```dart
        if (session.feedbackResult != null)
          for (final point in session.feedbackResult!.points) _FeedbackPointCard(point: point),
```

durch:

```dart
        if (session.feedbackResult != null)
          for (final point in session.feedbackResult!.points)
            _FeedbackPointCard(point: point, session: session),
```

Ersetze den kompletten `_FeedbackPointCard`-Klassenblock (von `class _FeedbackPointCard extends StatelessWidget {` bis zur letzten schließenden `}` der Datei) durch:

```dart
class _FeedbackPointCard extends StatefulWidget {
  final FeedbackPoint point;
  final SessionState session;

  const _FeedbackPointCard({required this.point, required this.session});

  @override
  State<_FeedbackPointCard> createState() => _FeedbackPointCardState();
}

class _FeedbackPointCardState extends State<_FeedbackPointCard> {
  bool _isBusy = false;
  String? _errorMessage;

  /// Startet die Wiedergabe der eigenen Aufnahme an der zur Karte gehoerenden
  /// Zeitstelle, mit 0,5s Vorlauf (max(0, jumpToT - 0.5)) - damit auch der
  /// Ansatz des bereits angesungenen Tons zu hoeren ist, nicht nur der Ton
  /// selbst. Der Vorlauf wird bewusst hier (mobile-seitig) angewendet, nicht im
  /// Backend - jump_to_t bleibt der reine Notenbeginn.
  Future<void> _jumpToPosition() async {
    final jumpToT = widget.point.jumpToT;
    final audioBytes = widget.session.sungAudioBytes;
    if (_isBusy || jumpToT == null || audioBytes == null) return;
    setState(() => _isBusy = true);
    try {
      final startSeconds = jumpToT - 0.5 < 0 ? 0.0 : jumpToT - 0.5;
      await widget.session.playFrom(
        audioBytes,
        Duration(milliseconds: (startSeconds * 1000).round()),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = 'Sprung fehlgeschlagen: $e');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final point = widget.point;
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(point.problem, style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
                if (point.jumpToT != null)
                  IconButton(
                    onPressed: _isBusy ? null : _jumpToPosition,
                    icon: const Icon(Icons.play_circle_outline),
                    tooltip: 'Zur Stelle springen',
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(point.technik),
            const SizedBox(height: 4),
            Text(point.uebung),
            if (point.wiederholungsaufgabe != null) ...[
              const SizedBox(height: 4),
              Text('Wiederholung: ${point.wiederholungsaufgabe}'),
            ],
            if (_errorMessage != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _errorMessage!,
                  style: TextStyle(color: Colors.red.shade300, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
```

`feedback_section.dart` braucht keinen neuen Import für diesen Schritt — `SessionState` ist bereits importiert, `AudioPlaybackController` wird hier nicht direkt referenziert.

- [ ] **Step 4: Tests ausführen, Erfolg bestätigen**

Run: `cd mobile && flutter test test/feedback_section_test.dart`
Expected: PASS, alle 7 Tests grün (4 bestehende + 3 neue).

- [ ] **Step 5: Vollen Test-Suite-Lauf und Analyse verifizieren**

Run: `cd mobile && flutter test -j 1`
Expected: alle Tests grün.

Run: `cd mobile && flutter analyze`
Expected: keine Fehler/Warnungen.

- [ ] **Step 6: Commit**

```bash
git add mobile/lib/widgets/feedback_section.dart mobile/test/feedback_section_test.dart
git commit -m "feat: add jump-to-audio-position button to feedback cards"
```

# Aufnahme nach dem Hochladen anhören Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Nutzer können eine bereits hochgeladene Aufnahme (Referenz oder Gesang) erneut
anhören, nicht nur in der Vorschau davor. Betrifft beide Aufnahme-Stellen.

**Architecture:** Die rohen Audio-Bytes werden nach erfolgreichem Analyse-Aufruf in
`SessionState` gehalten (nicht widget-lokal in `RecordingControl`), da die
`RecordingControl`-Instanz im Referenz-Abschnitt beim Umschalten MIDI/Referenz unmountet wird.
Ein neues, kleines `PlaybackButton`-Widget rendert einen Play/Pause-Button aus diesen Bytes,
mit demselben `_isBusy`-Guard-Muster wie `RecordingControl` (aus dem vorherigen Feature
übernommen, um dieselbe Await-Race-Klasse von Anfang an zu vermeiden).

**Tech Stack:** Flutter/Dart (`mobile/`), bestehendes `audioplayers`-Package (kein neues
Package nötig).

## Global Constraints

- Reine Wiedergabe-Funktion, kein Löschen der bereits hochgeladenen Aufnahme/Kurve.
- Kein Backend-Change.
- Gilt für Referenz- UND Gesangsaufnahme (beide Abschnitte).
- Kein neues Flutter-Package.
- Kein automatisierter Test für `PlaybackButton` selbst (Plattform-Channel-basiert, gleiche
  Begründung wie `RecordingControl`) — die bestehende Suite (aktuell 8/8) muss aber grün
  bleiben.

---

## Datei-Übersicht

- **Modify:** `mobile/lib/state/session_state.dart` — neue Felder `referenceAudioBytes`/
  `sungAudioBytes`, gesetzt in `analyzeReference`/`analyzeAudio`, `sungAudioBytes`
  zurückgesetzt in `_resetAudioSection`/`setReferenceSource`.
- **Create:** `mobile/lib/widgets/playback_button.dart` — neues wiederverwendbares Widget.
- **Modify:** `mobile/lib/screens/home_screen.dart` — `PlaybackButton` neben beiden
  `StatusBanner`s einbinden.
- **Modify:** `mobile/test/session_state_test.dart` — neue Tests für die Bytes-Persistenz.

---

### Task 1: State-Layer — Audio-Bytes in `SessionState` persistieren

**Files:**
- Modify: `mobile/lib/state/session_state.dart`
- Test: `mobile/test/session_state_test.dart`

**Interfaces:**
- Produces: `SessionState.referenceAudioBytes` (`Uint8List?`), `SessionState.sungAudioBytes`
  (`Uint8List?`). Beide werden von `analyzeReference`/`analyzeAudio` gesetzt, bevor der
  Analyse-Request läuft (auch bei Fehlschlag bleiben sie gesetzt). `sungAudioBytes` wird in
  `_resetAudioSection()` und `setReferenceSource()` auf `null` zurückgesetzt;
  `referenceAudioBytes` bleibt bei `setReferenceSource()`-Wechseln erhalten (genau wie
  `referenceRawCurve` heute schon).

- [ ] **Step 1: Schreibe die fehlschlagenden Tests**

Füge in `mobile/test/session_state_test.dart` am Ende der `main()`-Funktion (vor der
schließenden `}`) diese zwei Tests hinzu:

```dart
  test('analyzeAudio und analyzeReference setzen die Roh-Audio-Bytes fuer Playback-nach-Upload',
      () async {
    final session = _buildSession();
    final referenceBytes = Uint8List.fromList([1, 2, 3]);
    final sungBytes = Uint8List.fromList([4, 5, 6]);

    session.setReferenceSource(ReferenceSource.recording);
    await session.analyzeReference(referenceBytes, 'referenz.wav');
    await session.analyzeAudio(sungBytes, 'gesang.wav');

    expect(session.referenceAudioBytes, referenceBytes);
    expect(session.sungAudioBytes, sungBytes);
  });

  test('setReferenceSource setzt sungAudioBytes zurueck, referenceAudioBytes bleibt erhalten',
      () async {
    final session = _buildSession();
    session.setReferenceSource(ReferenceSource.recording);
    await session.analyzeReference(Uint8List.fromList([1, 2, 3]), 'referenz.wav');
    await session.analyzeAudio(Uint8List.fromList([4, 5, 6]), 'gesang.wav');

    session.setReferenceSource(ReferenceSource.midi);

    expect(session.sungAudioBytes, isNull);
    expect(session.referenceAudioBytes, isNotNull);
  });
```

- [ ] **Step 2: Test laufen lassen, um das erwartete Fehlschlagen zu bestätigen**

Run: `cd mobile && flutter test test/session_state_test.dart`
Expected: FAIL — Compile-Fehler, da `referenceAudioBytes`/`sungAudioBytes` in `SessionState`
noch nicht existieren.

- [ ] **Step 3: Implementiere die neuen Felder**

Öffne `mobile/lib/state/session_state.dart`. Füge nach der bestehenden Zeile

```dart
  String referenceMessage = '';
```

diese zwei Felder ein:

```dart
  Uint8List? referenceAudioBytes;
  Uint8List? sungAudioBytes;
```

Ersetze die bestehende `analyzeAudio`-Methode

```dart
  Future<void> analyzeAudio(Uint8List bytes, String filename) async {
    audioStatus = LoadStatus.loading;
    audioMessage = 'Analysiere Tonhöhe der Aufnahme…';
    notifyListeners();
    try {
      sungCurve = await audioApi.analyzeAudio(bytes, filename);
      audioStatus = LoadStatus.ok;
      audioMessage = 'Analyse fertig.';
    } catch (e) {
      audioStatus = LoadStatus.error;
      audioMessage = 'Fehler: ${_messageOf(e)}';
    }
    notifyListeners();
  }
```

durch (einzige Änderung: neue erste Zeile im Methodenkörper):

```dart
  Future<void> analyzeAudio(Uint8List bytes, String filename) async {
    sungAudioBytes = bytes;
    audioStatus = LoadStatus.loading;
    audioMessage = 'Analysiere Tonhöhe der Aufnahme…';
    notifyListeners();
    try {
      sungCurve = await audioApi.analyzeAudio(bytes, filename);
      audioStatus = LoadStatus.ok;
      audioMessage = 'Analyse fertig.';
    } catch (e) {
      audioStatus = LoadStatus.error;
      audioMessage = 'Fehler: ${_messageOf(e)}';
    }
    notifyListeners();
  }
```

Ersetze die bestehende `analyzeReference`-Methode

```dart
  Future<void> analyzeReference(Uint8List bytes, String filename) async {
    referenceStatus = LoadStatus.loading;
    referenceMessage = 'Analysiere Referenzaufnahme…';
    notifyListeners();
    try {
      referenceRawCurve = await audioApi.analyzeAudio(bytes, filename);
      referenceStatus = LoadStatus.ok;
      referenceMessage =
          'Referenz analysiert. Jetzt eine Gesangsaufnahme aufnehmen oder hochladen.';
    } catch (e) {
      referenceStatus = LoadStatus.error;
      referenceMessage = 'Fehler: ${_messageOf(e)}';
    }
    notifyListeners();
  }
```

durch (einzige Änderung: neue erste Zeile im Methodenkörper):

```dart
  Future<void> analyzeReference(Uint8List bytes, String filename) async {
    referenceAudioBytes = bytes;
    referenceStatus = LoadStatus.loading;
    referenceMessage = 'Analysiere Referenzaufnahme…';
    notifyListeners();
    try {
      referenceRawCurve = await audioApi.analyzeAudio(bytes, filename);
      referenceStatus = LoadStatus.ok;
      referenceMessage =
          'Referenz analysiert. Jetzt eine Gesangsaufnahme aufnehmen oder hochladen.';
    } catch (e) {
      referenceStatus = LoadStatus.error;
      referenceMessage = 'Fehler: ${_messageOf(e)}';
    }
    notifyListeners();
  }
```

Ersetze die bestehende `setReferenceSource`-Methode

```dart
  void setReferenceSource(ReferenceSource source) {
    if (source == referenceSource) return;
    referenceSource = source;
    sungCurve = [];
    audioStatus = LoadStatus.idle;
    audioMessage = '';
    notifyListeners();
  }
```

durch:

```dart
  void setReferenceSource(ReferenceSource source) {
    if (source == referenceSource) return;
    referenceSource = source;
    sungCurve = [];
    sungAudioBytes = null;
    audioStatus = LoadStatus.idle;
    audioMessage = '';
    notifyListeners();
  }
```

Ersetze die bestehende `_resetAudioSection`-Methode

```dart
  void _resetAudioSection() {
    selectedTrackIndex = null;
    targetCurve = [];
    sungCurve = [];
    audioStatus = LoadStatus.idle;
    audioMessage = '';
  }
```

durch:

```dart
  void _resetAudioSection() {
    selectedTrackIndex = null;
    targetCurve = [];
    sungCurve = [];
    sungAudioBytes = null;
    audioStatus = LoadStatus.idle;
    audioMessage = '';
  }
```

- [ ] **Step 4: Tests laufen lassen, um das Bestehen zu bestätigen**

Run: `cd mobile && flutter test test/session_state_test.dart`
Expected: PASS (alle 8 Tests grün — die 6 bestehenden plus die 2 neuen)

- [ ] **Step 5: Bestehende Tests gegenprüfen**

Run: `cd mobile && flutter test test/widget_test.dart`
Expected: PASS (2/2, unverändert — dieser Task ändert kein von diesen Tests geprüftes
Verhalten)

- [ ] **Step 6: Commit**

```bash
git add mobile/lib/state/session_state.dart mobile/test/session_state_test.dart
git commit -m "feat: persist confirmed recording bytes in SessionState for playback-after-upload"
```

---

### Task 2: `PlaybackButton`-Widget + Einbindung in `home_screen.dart`

**Files:**
- Create: `mobile/lib/widgets/playback_button.dart`
- Modify: `mobile/lib/screens/home_screen.dart`

**Interfaces:**
- Consumes: `SessionState.referenceAudioBytes`, `SessionState.sungAudioBytes` (aus Task 1).
- Produces: `PlaybackButton` (`StatefulWidget`, Konstruktor `PlaybackButton({Key? key,
  required Uint8List? audioBytes})`), keine weiteren öffentlichen Symbole.

- [ ] **Step 1: Erstelle `playback_button.dart`**

Erstelle `mobile/lib/widgets/playback_button.dart` mit folgendem Inhalt:

```dart
import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

/// Spielt eine bereits hochgeladene Aufnahme erneut ab (im Gegensatz zu
/// RecordingControls Vorschau, die nur *vor* dem Hochladen existiert). Rendert
/// nichts, solange keine Bytes vorliegen. Gleiches _isBusy-Guard-Muster wie
/// RecordingControl, um dieselbe Await-Race-Klasse zu vermeiden.
class PlaybackButton extends StatefulWidget {
  final Uint8List? audioBytes;

  const PlaybackButton({super.key, required this.audioBytes});

  @override
  State<PlaybackButton> createState() => _PlaybackButtonState();
}

class _PlaybackButtonState extends State<PlaybackButton> {
  final AudioPlayer _player = AudioPlayer();
  late final StreamSubscription<void> _playerCompleteSubscription;
  bool _isPlaying = false;
  bool _isBusy = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _playerCompleteSubscription = _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _isPlaying = false);
    });
  }

  @override
  void didUpdateWidget(covariant PlaybackButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.audioBytes != oldWidget.audioBytes) {
      unawaited(_player.stop());
      _isPlaying = false;
      _errorMessage = null;
    }
  }

  @override
  void dispose() {
    _playerCompleteSubscription.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _togglePlayback() async {
    if (_isBusy || widget.audioBytes == null) return;
    setState(() => _isBusy = true);
    try {
      if (_isPlaying) {
        await _player.pause();
        setState(() => _isPlaying = false);
      } else {
        await _player.play(BytesSource(widget.audioBytes!));
        setState(() => _isPlaying = true);
      }
    } catch (e) {
      setState(() => _errorMessage = 'Wiedergabe fehlgeschlagen: $e');
    } finally {
      setState(() => _isBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.audioBytes == null) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: _isBusy ? null : _togglePlayback,
          icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
          tooltip: _isPlaying ? 'Pause' : 'Erneut abspielen',
        ),
        if (_errorMessage != null)
          Flexible(
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

- [ ] **Step 2: `home_screen.dart` einbinden**

Öffne `mobile/lib/screens/home_screen.dart`. Füge nach der bestehenden Import-Zeile
`import '../widgets/pitch_chart.dart';` diese Zeile ein:

```dart
import '../widgets/playback_button.dart';
```

Ersetze im Referenz-Zweig (`else`-Branch der `if (session.referenceSource ==
ReferenceSource.midi)`-Bedingung) die Zeile

```dart
              StatusBanner(status: session.referenceStatus, message: session.referenceMessage),
```

durch:

```dart
              Row(
                children: [
                  Expanded(
                    child: StatusBanner(
                      status: session.referenceStatus,
                      message: session.referenceMessage,
                    ),
                  ),
                  PlaybackButton(audioBytes: session.referenceAudioBytes),
                ],
              ),
```

Ersetze in Abschnitt 2 die Zeile

```dart
            StatusBanner(status: session.audioStatus, message: session.audioMessage),
```

durch:

```dart
            Row(
              children: [
                Expanded(
                  child: StatusBanner(
                    status: session.audioStatus,
                    message: session.audioMessage,
                  ),
                ),
                PlaybackButton(audioBytes: session.sungAudioBytes),
              ],
            ),
```

- [ ] **Step 3: Statische Analyse**

Run: `cd mobile && flutter analyze`
Expected: "No issues found!"

- [ ] **Step 4: Bestehende Test-Suite gegenprüfen**

Run: `cd mobile && flutter test test/widget_test.dart` und
`flutter test test/session_state_test.dart` einzeln.
Expected: weiterhin 2/2 + 8/8 bestehend (Task 1 hat die Session-State-Suite bereits auf 8
Tests gebracht), unverändert.

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/widgets/playback_button.dart mobile/lib/screens/home_screen.dart
git commit -m "feat: add playback-after-upload button to both recording sections"
```

---

### Task 3: Manuelle End-to-End-Verifikation

**Files:** keine (reine Verifikation, keine Code-Änderung)

**Interfaces:**
- Consumes: laufender Android-Emulator (`emulator-5554`, aus vorherigen Sessions bereits
  eingerichtet — falls nicht mehr aktiv, neu starten mit `/home/jrive/Android/sdk/emulator/
  emulator -avd redesign_test -no-window -no-audio -no-boot-anim -gpu swiftshader_indirect`
  und auf `adb -s emulator-5554 shell getprop sys.boot_completed` warten), Backend-Instanz
  (`backend/main.py`, `--host 0.0.0.0`).

- [ ] **Step 1: App auf dem Emulator starten**

Run: `cd mobile && flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8000 -d
emulator-5554`

- [ ] **Step 2: Referenzaufnahme aufnehmen und bestätigen**

Umschalter auf "Eigene Aufnahme", aufnehmen, "Verwenden" antippen. Nach Abschluss der Analyse:
prüfen, dass neben der Erfolgsmeldung ("Referenz analysiert…") jetzt ein Play-Button
erscheint. Antippen → Wiedergabe hörbar, Icon wechselt zu Pause.

- [ ] **Step 3: Gesangsaufnahme aufnehmen und bestätigen**

Analog in Abschnitt 2: aufnehmen, "Verwenden", Play-Button neben "Analyse fertig." erscheint
und funktioniert.

- [ ] **Step 4: Persistenz über Moduswechsel prüfen**

Im Referenz-Abschnitt auf "MIDI-Datei" umschalten und zurück auf "Eigene Aufnahme" — der
Play-Button für die Referenzaufnahme muss weiterhin da sein und funktionieren (das war der
Grund für Ansatz B). Prüfen, dass der Play-Button in Abschnitt 2 (Gesang) nach dem
Umschalten weiterhin sichtbar bleibt, aber die Aufnahme dort **verschwindet**, sobald eine
neue MIDI-Datei hochgeladen wird oder der Referenz-Modus gewechselt wird (siehe bestehendes
Reset-Verhalten, mit dem Nutzer bereits abgestimmt).

Expected: Beide Play-Buttons funktionieren unabhängig voneinander, keine Abstürze, kein
Wiedergabe-Rest nach einer neuen Aufnahme (alte Wiedergabe stoppt automatisch beim Ersetzen).

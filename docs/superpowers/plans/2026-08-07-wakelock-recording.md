# Wakelock während der Aufnahme Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Verhindern, dass das Display während einer laufenden Mikrofonaufnahme ausgeht (Android-Display-Timeout), da dies bestätigt zu lautlosem Audioverlust in der Aufnahme führt.

**Architecture:** Eine neue, für sich testbare Klasse `RecordingWakelock` (Datei `mobile/lib/util/recording_wakelock.dart`) kapselt einen Referenzzähler über injectable Enable/Disable-Hooks (Default: `WakelockPlus.enable`/`WakelockPlus.disable` aus dem `wakelock_plus`-Paket). Ein einziges, geteiltes Top-Level-Singleton dieser Klasse wird von beiden `RecordingControl`-Widget-Instanzen (Referenz- und Gesangsaufnahme-Abschnitt in `home_screen.dart`) verwendet, damit paralleles/verschachteltes Starten/Stoppen den Wakelock korrekt hält, bis wirklich keine Aufnahme mehr läuft.

**Tech Stack:** Flutter/Dart, Paket `wakelock_plus` (neue Abhängigkeit), `flutter_test`.

## Global Constraints

- Paket: `wakelock_plus: ^1.7.0` in `mobile/pubspec.yaml`.
- Kein Foreground-Service, kein `WidgetsBindingObserver`, keine
  Unterbrechungs-Erkennung/-Warnung — nur Wakelock (explizite Nutzerwahl,
  siehe Spec).
- Keine nativen Manifest-/Plist-Änderungen nötig: `wakelock_plus` verwendet
  `FLAG_KEEP_SCREEN_ON` (Android) bzw. `UIApplication.isIdleTimerDisabled`
  (iOS) — beides erfordert keine zusätzliche Berechtigung/Konfiguration.
- Neue Datei liegt unter `mobile/lib/util/` (neues Verzeichnis, existiert
  noch nicht).

---

### Task 1: RecordingWakelock-Klasse mit Referenzzähler

**Files:**
- Create: `mobile/lib/util/recording_wakelock.dart`
- Modify: `mobile/pubspec.yaml`
- Test: `mobile/test/recording_wakelock_test.dart`

**Interfaces:**
- Produces: `class RecordingWakelock` mit Konstruktor
  `RecordingWakelock({Future<void> Function() enable = WakelockPlus.enable, Future<void> Function() disable = WakelockPlus.disable})`,
  Methoden `Future<void> acquire()` und `Future<void> release()`. Ein
  Top-Level-Singleton `final RecordingWakelock recordingWakelock = RecordingWakelock();`
  in derselben Datei, das Task 2 importiert und verwendet.

- [ ] **Step 1: Abhängigkeit hinzufügen**

In `mobile/pubspec.yaml`, im `dependencies:`-Block, nach der Zeile
`share_plus: ^12.0.2` folgende Zeile einfügen:

```yaml
  wakelock_plus: ^1.7.0
```

Dann ausführen: `cd mobile && flutter pub get`

- [ ] **Step 2: Fehlschlagenden Test schreiben**

Neue Datei `mobile/test/recording_wakelock_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:singing_feedback_mobile/util/recording_wakelock.dart';

void main() {
  test('zwei acquire() loesen genau einen enable-Aufruf aus', () async {
    var enableCalls = 0;
    var disableCalls = 0;
    final wakelock = RecordingWakelock(
      enable: () async => enableCalls++,
      disable: () async => disableCalls++,
    );

    await wakelock.acquire();
    await wakelock.acquire();

    expect(enableCalls, 1);
    expect(disableCalls, 0);
  });

  test('erst der letzte release() loest disable aus', () async {
    var enableCalls = 0;
    var disableCalls = 0;
    final wakelock = RecordingWakelock(
      enable: () async => enableCalls++,
      disable: () async => disableCalls++,
    );

    await wakelock.acquire();
    await wakelock.acquire();
    await wakelock.release();
    expect(disableCalls, 0);
    await wakelock.release();
    expect(disableCalls, 1);
    expect(enableCalls, 1);
  });

  test('einzelnes acquire/release-Paar loest je einen enable/disable aus', () async {
    var enableCalls = 0;
    var disableCalls = 0;
    final wakelock = RecordingWakelock(
      enable: () async => enableCalls++,
      disable: () async => disableCalls++,
    );

    await wakelock.acquire();
    expect(enableCalls, 1);
    expect(disableCalls, 0);
    await wakelock.release();
    expect(disableCalls, 1);
  });

  test('release() ohne vorheriges acquire() ist ein No-op', () async {
    var enableCalls = 0;
    var disableCalls = 0;
    final wakelock = RecordingWakelock(
      enable: () async => enableCalls++,
      disable: () async => disableCalls++,
    );

    await wakelock.release();

    expect(enableCalls, 0);
    expect(disableCalls, 0);
  });

  test('drei acquire() und drei release() balancieren sich exakt aus', () async {
    var enableCalls = 0;
    var disableCalls = 0;
    final wakelock = RecordingWakelock(
      enable: () async => enableCalls++,
      disable: () async => disableCalls++,
    );

    await wakelock.acquire();
    await wakelock.acquire();
    await wakelock.acquire();
    await wakelock.release();
    await wakelock.release();
    expect(disableCalls, 0);
    await wakelock.release();
    expect(enableCalls, 1);
    expect(disableCalls, 1);
  });
}
```

- [ ] **Step 3: Test laufen lassen, Fehlschlag bestätigen**

Run: `cd mobile && flutter test test/recording_wakelock_test.dart`
Expected: FAIL (Datei `lib/util/recording_wakelock.dart` existiert noch
nicht, Compile-Fehler "Target of URI doesn't exist").

- [ ] **Step 4: RecordingWakelock implementieren**

Neue Datei `mobile/lib/util/recording_wakelock.dart`:

```dart
import 'package:wakelock_plus/wakelock_plus.dart';

/// Haelt das Display waehrend einer laufenden Mikrofonaufnahme wach
/// (Android-Display-Timeout fuehrt sonst bestaetigt zu lautlosem
/// Audioverlust). Ein Referenzzaehler erlaubt mehreren unabhaengigen
/// Aufnahme-Widgets (Referenz- und Gesangsaufnahme), sich denselben
/// Wakelock-Zustand zu teilen, ohne sich gegenseitig vorzeitig
/// abzuschalten.
class RecordingWakelock {
  RecordingWakelock({
    Future<void> Function() enable = WakelockPlus.enable,
    Future<void> Function() disable = WakelockPlus.disable,
  })  : _enable = enable,
        _disable = disable;

  final Future<void> Function() _enable;
  final Future<void> Function() _disable;
  int _activeRecordings = 0;

  Future<void> acquire() async {
    _activeRecordings++;
    if (_activeRecordings == 1) {
      await _enable();
    }
  }

  Future<void> release() async {
    if (_activeRecordings == 0) return;
    _activeRecordings--;
    if (_activeRecordings == 0) {
      await _disable();
    }
  }
}

/// Von allen RecordingControl-Instanzen geteiltes Singleton.
final RecordingWakelock recordingWakelock = RecordingWakelock();
```

- [ ] **Step 5: Test laufen lassen, Erfolg bestätigen**

Run: `cd mobile && flutter test test/recording_wakelock_test.dart`
Expected: PASS (5 Tests)

- [ ] **Step 6: Commit**

```bash
cd mobile && git add pubspec.yaml pubspec.lock lib/util/recording_wakelock.dart test/recording_wakelock_test.dart
git commit -m "feat: add RecordingWakelock reference-counted wakelock helper"
```

---

### Task 2: RecordingWakelock in RecordingControl verdrahten

**Files:**
- Modify: `mobile/lib/widgets/recording_control.dart`

**Interfaces:**
- Consumes: `recordingWakelock` (Top-Level-Singleton aus Task 1,
  `mobile/lib/util/recording_wakelock.dart`), Methoden `acquire()`/`release()`.

- [ ] **Step 1: Import und Instanz-Flag hinzufügen**

In `mobile/lib/widgets/recording_control.dart`, nach der bestehenden
`import 'package:record/record.dart';`-Zeile (Zeile 9) einfügen:

```dart
import 'package:singing_feedback_mobile/util/recording_wakelock.dart';
```

In `_RecordingControlState`, nach der Feld-Deklaration `bool _isBusy = false;`
(Zeile 33) einfügen:

```dart
  bool _holdsWakelock = false;
```

- [ ] **Step 2: Wakelock in `_startRecording()` anfordern**

In `_startRecording()` (aktuell Zeilen 54-69), die letzte Zeile

```dart
    await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
    setState(() => _isRecording = true);
```

ersetzen durch:

```dart
    await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
    await recordingWakelock.acquire();
    _holdsWakelock = true;
    setState(() => _isRecording = true);
```

- [ ] **Step 3: Wakelock in `_stopRecording()` freigeben**

In `_stopRecording()` (aktuell Zeilen 71-80):

```dart
  Future<void> _stopRecording() async {
    final path = await _recorder.stop();
    setState(() => _isRecording = false);
    if (path == null) return;
    final bytes = await File(path).readAsBytes();
    setState(() {
      _pendingAudio = bytes;
      _pendingFilename = 'aufnahme.m4a';
    });
  }
```

ersetzen durch:

```dart
  Future<void> _stopRecording() async {
    final path = await _recorder.stop();
    if (_holdsWakelock) {
      _holdsWakelock = false;
      await recordingWakelock.release();
    }
    setState(() => _isRecording = false);
    if (path == null) return;
    final bytes = await File(path).readAsBytes();
    setState(() {
      _pendingAudio = bytes;
      _pendingFilename = 'aufnahme.m4a';
    });
  }
```

- [ ] **Step 4: Sicherheitsnetz in `dispose()`**

In `dispose()` (aktuell Zeilen 46-52):

```dart
  @override
  void dispose() {
    _playerCompleteSubscription.cancel();
    _recorder.dispose();
    _player.dispose();
    super.dispose();
  }
```

ersetzen durch:

```dart
  @override
  void dispose() {
    _playerCompleteSubscription.cancel();
    _recorder.dispose();
    _player.dispose();
    if (_holdsWakelock) {
      _holdsWakelock = false;
      recordingWakelock.release();
    }
    super.dispose();
  }
```

(`release()` wird hier bewusst nicht `await`et — `dispose()` ist synchron;
`RecordingWakelock.release()` selbst bleibt korrekt, weil `_holdsWakelock`
vor dem Aufruf auf `false` gesetzt wird, ein erneuter `dispose()`-Aufruf
also nicht doppelt dekrementiert.)

- [ ] **Step 5: Volle Testsuite laufen lassen**

Run: `cd mobile && flutter test`
Expected: PASS (alle bestehenden Tests weiterhin gruen, inkl.
`test/widget_test.dart` und `test/recording_wakelock_test.dart` aus Task 1
— `widget_test.dart` pumpt `RecordingControl`, tippt aber nie auf
"Aufnehmen", ruft also `_startRecording()`/`recordingWakelock.acquire()`
nie auf; kein `MissingPluginException`-Risiko in der Testumgebung).

- [ ] **Step 6: Commit**

```bash
cd mobile && git add lib/widgets/recording_control.dart
git commit -m "feat: keep screen on during microphone recording via RecordingWakelock"
```

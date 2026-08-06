# Gesangsaufnahme teilen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ein neuer Teilen-Button neben dem bestehenden `PlaybackButton` in Abschnitt "2. Gesangsaufnahme" öffnet den nativen Betriebssystem-Teilen-Dialog mit der Gesangsaufnahme (funktioniert automatisch mit WhatsApp und jeder anderen installierten App).

**Architecture:** `share_plus` für den nativen Teilen-Dialog, `XFile.fromData(...)` direkt aus den bereits im Speicher gehaltenen Aufnahme-Bytes (keine temporäre Datei nötig). `SessionState` bekommt ein neues Feld für den Dateinamen der Gesangsaufnahme, damit die geteilte Datei die richtige Endung hat.

**Tech Stack:** Flutter/Dart, neues Paket `share_plus`.

## Global Constraints

- Nur die Gesangsaufnahme (Abschnitt "2. Gesangsaufnahme") bekommt einen Teilen-Button — nicht die Referenzaufnahme.
- Kein Begleittext beim Teilen — nur die Audiodatei.
- Kein Umweg über eine temporäre Datei — `XFile.fromData(...)` direkt aus den Bytes.
- Fehlerbehandlung/Busy-Guard folgt dem bestehenden `PlaybackButton`-Muster (`mobile/lib/widgets/playback_button.dart`), inklusive injizierbarer Abstraktion für Tests.

---

### Task 1: Dateiname der Gesangsaufnahme in `SessionState` speichern

**Files:**
- Modify: `mobile/lib/state/session_state.dart`
- Modify: `mobile/test/session_state_test.dart`

**Interfaces:**
- Produces: `SessionState.sungAudioFilename` (`String?`, neues Feld) — wird von `analyzeAudio()` zusammen mit `sungAudioBytes` gesetzt und überall dort auf `null` zurückgesetzt, wo auch `sungAudioBytes` zurückgesetzt wird.

`analyzeAudio(Uint8List bytes, String filename)` bekommt den Dateinamen bereits als Parameter (aktuell nur an `audioApi.analyzeAudio()` weitergereicht, nicht im State gehalten) — dieser Task speichert ihn zusätzlich, ohne sonst etwas an der bestehenden Logik zu ändern.

- [ ] **Step 1: Test an `mobile/test/session_state_test.dart` anhängen**

Am Ende von `main()` (nach dem letzten bestehenden Test, vor der abschließenden `}`), anfügen:

```dart

  test('analyzeAudio speichert den Dateinamen der Gesangsaufnahme', () async {
    final session = _buildSession();
    session.midiSessionId = 'sess-1';
    session.selectedTrackIndex = 0;
    session.targetCurve = const [TargetPoint(t: 0.0, hz: 440.0, midiNote: 69)];

    await session.analyzeAudio(Uint8List.fromList([1, 2, 3]), 'aufnahme.m4a');

    expect(session.sungAudioFilename, 'aufnahme.m4a');
  });

  test('setReferenceSource setzt sungAudioFilename zurueck, wenn sungAudioBytes zurueckgesetzt wird',
      () async {
    final session = _buildSession();
    session.midiSessionId = 'sess-1';
    session.selectedTrackIndex = 0;
    session.targetCurve = const [TargetPoint(t: 0.0, hz: 440.0, midiNote: 69)];
    await session.analyzeAudio(Uint8List.fromList([1, 2, 3]), 'aufnahme.m4a');
    expect(session.sungAudioFilename, 'aufnahme.m4a');

    session.setReferenceSource(ReferenceSource.recording);

    expect(session.sungAudioFilename, isNull);
  });
```

- [ ] **Step 2: Test laufen lassen — FAIL erwarten**

Run: `cd mobile && flutter test test/session_state_test.dart`
Expected: FAIL (Compile-Fehler, `sungAudioFilename` existiert noch nicht auf `SessionState`).

- [ ] **Step 3: `mobile/lib/state/session_state.dart` erweitern**

Nach `Uint8List? sungAudioBytes;` (`mobile/lib/state/session_state.dart:52`) ergänzen:

```dart
  String? sungAudioFilename;
```

`analyzeAudio()`s erste Zeile (`mobile/lib/state/session_state.dart:162`, `sungAudioBytes = bytes;`) ergänzen um:

```dart
    sungAudioBytes = bytes;
    sungAudioFilename = filename;
```

`setReferenceSource()` (`mobile/lib/state/session_state.dart:277`, `sungAudioBytes = null;`) ergänzen um:

```dart
    sungAudioBytes = null;
    sungAudioFilename = null;
```

`_resetAudioSection()` (`mobile/lib/state/session_state.dart:288`, `sungAudioBytes = null;`) ergänzen um:

```dart
    sungAudioBytes = null;
    sungAudioFilename = null;
```

- [ ] **Step 4: Tests laufen lassen**

Run: `cd mobile && flutter test test/session_state_test.dart`
Expected: alle Tests (bestehende + 2 neue) PASS.

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/state/session_state.dart mobile/test/session_state_test.dart
git commit -m "feat: store the sung recording's filename in SessionState"
```

---

### Task 2: `ShareButton`-Widget bauen und in HomeScreen einhängen

**Files:**
- Modify: `mobile/pubspec.yaml` (neue Abhängigkeit `share_plus`)
- Create: `mobile/lib/widgets/share_button.dart`
- Create: `mobile/test/share_button_test.dart`
- Modify: `mobile/lib/screens/home_screen.dart`

**Interfaces:**
- Consumes: `SessionState.sungAudioBytes`, `SessionState.sungAudioFilename` (Task 1).
- Produces: `ShareController` (abstrakte Klasse, `Future<void> shareBytes(Uint8List bytes, String filename)`), `ShareButton` Widget (`{required Uint8List? audioBytes, required String? filename, ShareController Function()? controllerFactory}`).

- [ ] **Step 1: `share_plus`-Abhängigkeit hinzufügen**

Run: `cd mobile && flutter pub add share_plus`

Das trägt automatisch die aktuell kompatible Version in `mobile/pubspec.yaml` ein und aktualisiert `pubspec.lock`. Danach `flutter pub get` erneut laufen lassen, falls `pub add` das nicht schon selbst tut, und `flutter analyze` einmal ausführen, um sicherzustellen, dass das neue Paket sauber auflöst (keine Versionskonflikte mit den bestehenden, teils gepinnten Paketen wie `file_picker: 10.3.10`).

- [ ] **Step 2: Test schreiben — `mobile/test/share_button_test.dart`**

```dart
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singing_feedback_mobile/widgets/share_button.dart';

/// Fake-Implementierung von [ShareController] fuer Tests, ganz ohne echten
/// Plattform-Kanal - analog zu _FakePlaybackController in playback_button_test.dart.
class _FakeShareController implements ShareController {
  Completer<void>? shareCompleter;
  Object? throwOnShare;
  int shareCallCount = 0;
  Uint8List? lastBytes;
  String? lastFilename;

  @override
  Future<void> shareBytes(Uint8List bytes, String filename) async {
    shareCallCount++;
    lastBytes = bytes;
    lastFilename = filename;
    if (shareCompleter != null) {
      await shareCompleter!.future;
    }
    if (throwOnShare != null) throw throwOnShare!;
  }
}

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('ShareButton', () {
    testWidgets('rendert nichts ohne audioBytes/filename', (tester) async {
      await tester.pumpWidget(
        _wrap(const ShareButton(audioBytes: null, filename: null)),
      );

      expect(find.byIcon(Icons.share), findsNothing);
    });

    testWidgets('Tap loest shareBytes mit den richtigen Bytes/Dateinamen aus', (tester) async {
      final fake = _FakeShareController();
      final bytes = Uint8List.fromList([1, 2, 3]);

      await tester.pumpWidget(
        _wrap(ShareButton(
          audioBytes: bytes,
          filename: 'aufnahme.m4a',
          controllerFactory: () => fake,
        )),
      );

      await tester.tap(find.byIcon(Icons.share));
      await tester.pumpAndSettle();

      expect(fake.shareCallCount, 1);
      expect(fake.lastBytes, bytes);
      expect(fake.lastFilename, 'aufnahme.m4a');
    });

    testWidgets(
        'Busy-Guard verhindert einen zweiten Share-Aufruf, waehrend der erste noch laeuft',
        (tester) async {
      final fake = _FakeShareController()..shareCompleter = Completer<void>();
      final bytes = Uint8List.fromList([1, 2, 3]);

      await tester.pumpWidget(
        _wrap(ShareButton(
          audioBytes: bytes,
          filename: 'aufnahme.m4a',
          controllerFactory: () => fake,
        )),
      );

      await tester.tap(find.byIcon(Icons.share));
      await tester.pump();

      final button = tester.widget<IconButton>(find.byType(IconButton));
      expect(button.onPressed, isNull);

      await tester.tap(find.byIcon(Icons.share));
      await tester.pump();

      expect(fake.shareCallCount, 1);

      fake.shareCompleter!.complete();
      await tester.pump();
      await tester.pump();

      expect(fake.shareCallCount, 1);
    });

    testWidgets('zeigt eine Fehlermeldung, wenn das Teilen fehlschlaegt', (tester) async {
      final fake = _FakeShareController()..throwOnShare = Exception('Kein Ziel gefunden');
      final bytes = Uint8List.fromList([1, 2, 3]);

      await tester.pumpWidget(
        _wrap(ShareButton(
          audioBytes: bytes,
          filename: 'aufnahme.m4a',
          controllerFactory: () => fake,
        )),
      );

      await tester.tap(find.byIcon(Icons.share));
      await tester.pumpAndSettle();

      expect(find.textContaining('Teilen fehlgeschlagen'), findsOneWidget);
    });

    testWidgets(
        'kein setState-Fehler, wenn das Widget waehrend eines ausstehenden Share-Aufrufs '
        'unmounted wird', (tester) async {
      final fake = _FakeShareController()..shareCompleter = Completer<void>();
      final bytes = Uint8List.fromList([1, 2, 3]);

      await tester.pumpWidget(
        _wrap(ShareButton(
          audioBytes: bytes,
          filename: 'aufnahme.m4a',
          controllerFactory: () => fake,
        )),
      );

      await tester.tap(find.byIcon(Icons.share));
      await tester.pump();

      await tester.pumpWidget(_wrap(const SizedBox.shrink()));

      fake.shareCompleter!.complete();
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  });
}
```

- [ ] **Step 3: Test laufen lassen — FAIL erwarten**

Run: `cd mobile && flutter test test/share_button_test.dart`
Expected: FAIL (`share_button.dart` existiert noch nicht).

- [ ] **Step 4: `mobile/lib/widgets/share_button.dart` implementieren**

```dart
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

/// Duenne Abstraktion ueber den nativen Teilen-Dialog, injizierbar fuer Tests -
/// analog zu AudioPlaybackController in playback_button.dart.
abstract class ShareController {
  Future<void> shareBytes(Uint8List bytes, String filename);
}

/// Standardimplementierung, delegiert an share_plus. Baut die Datei direkt aus
/// den im Speicher gehaltenen Bytes (XFile.fromData) - kein Umweg ueber eine
/// temporaere Datei, passend zur bestehenden Praxis im Projekt (siehe
/// PlaybackButton, das genauso BytesSource statt einer Temp-Datei nutzt).
class _RealShareController implements ShareController {
  @override
  Future<void> shareBytes(Uint8List bytes, String filename) async {
    final file = XFile.fromData(bytes, name: filename, mimeType: _mimeTypeFor(filename));
    await SharePlus.instance.share(ShareParams(files: [file]));
  }

  String? _mimeTypeFor(String filename) {
    final lower = filename.toLowerCase();
    if (lower.endsWith('.m4a')) return 'audio/mp4';
    if (lower.endsWith('.wav')) return 'audio/wav';
    if (lower.endsWith('.mp3')) return 'audio/mpeg';
    return null;
  }
}

/// Teilt eine bereits hochgeladene Gesangsaufnahme ueber den nativen
/// Betriebssystem-Teilen-Dialog (WhatsApp, andere Messenger, ...). Rendert
/// nichts, solange keine Aufnahme vorliegt. Gleiches _isBusy-Guard-Muster wie
/// PlaybackButton, um Doppel-Taps waehrend des offenen Teilen-Dialogs zu
/// vermeiden.
class ShareButton extends StatefulWidget {
  final Uint8List? audioBytes;
  final String? filename;

  /// Fabrik fuer den Share-Controller, injizierbar fuer Tests (siehe
  /// [ShareController]). Standardmaessig die echte Implementierung.
  final ShareController Function() controllerFactory;

  ShareButton({
    super.key,
    required this.audioBytes,
    required this.filename,
    ShareController Function()? controllerFactory,
  }) : controllerFactory = controllerFactory ?? (() => _RealShareController());

  @override
  State<ShareButton> createState() => _ShareButtonState();
}

class _ShareButtonState extends State<ShareButton> {
  late final ShareController _controller = widget.controllerFactory();
  bool _isBusy = false;
  String? _errorMessage;

  Future<void> _share() async {
    if (_isBusy || widget.audioBytes == null || widget.filename == null) return;
    setState(() {
      _isBusy = true;
      _errorMessage = null;
    });
    try {
      await _controller.shareBytes(widget.audioBytes!, widget.filename!);
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = 'Teilen fehlgeschlagen: $e');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.audioBytes == null || widget.filename == null) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IconButton(
          onPressed: _isBusy ? null : _share,
          icon: const Icon(Icons.share),
          tooltip: 'Teilen',
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

**Hinweis zur `share_plus`-API:** Die obige `SharePlus.instance.share(ShareParams(files: [file]))`-Aufrufform entspricht der API ab `share_plus` 10.x. Falls `flutter pub add` (Step 1) eine andere Hauptversion mit einer abweichenden API installiert (z.B. noch das ältere `Share.shareXFiles([file])`), passe `_RealShareController.shareBytes` an die tatsächlich installierte API an — der Rest der Datei (die `ShareController`-Abstraktion, `ShareButton`) bleibt davon unberührt, da nur `_RealShareController` die konkrete `share_plus`-API direkt aufruft.

- [ ] **Step 5: Tests laufen lassen**

Run: `cd mobile && flutter test test/share_button_test.dart`
Expected: alle 5 Tests PASS.

- [ ] **Step 6: `mobile/lib/screens/home_screen.dart` — `ShareButton` neben `PlaybackButton` einhängen**

Import ergänzen (nach `import '../widgets/score_summary_view.dart';`, `mobile/lib/screens/home_screen.dart:9`):

```dart
import '../widgets/share_button.dart';
```

Den bestehenden `Row`-Block in Abschnitt "2. Gesangsaufnahme" (`mobile/lib/screens/home_screen.dart:104-117`) ersetzen durch:

```dart
            Row(
              children: [
                Expanded(
                  child: StatusBanner(
                    status: session.audioStatus,
                    message: session.audioMessage,
                  ),
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 180),
                  child: PlaybackButton(audioBytes: session.sungAudioBytes),
                ),
                ShareButton(
                  audioBytes: session.sungAudioBytes,
                  filename: session.sungAudioFilename,
                ),
              ],
            ),
```

(Einzige Änderung: ein neues `ShareButton(...)` als drittes Kind der `Row`, nach dem bestehenden `PlaybackButton`. Sonst unverändert.)

- [ ] **Step 7: Statische Analyse + vollständiger Testlauf**

Run: `cd mobile && flutter analyze && flutter test`
Expected: keine neuen Analyzer-Fehler, alle Tests PASS.

- [ ] **Step 8: Manuelle Verifikation im Emulator/Gerät**

App starten, eine Gesangsaufnahme aufnehmen oder hochladen, den neuen Teilen-Button (Icon neben dem Abspiel-Button) antippen, prüfen, dass der native Teilen-Dialog mit der Audiodatei erscheint und z.B. an eine installierte Messenger-App weitergegeben werden kann.

- [ ] **Step 9: Commit**

```bash
git add mobile/pubspec.yaml mobile/pubspec.lock mobile/lib/widgets/share_button.dart mobile/test/share_button_test.dart mobile/lib/screens/home_screen.dart
git commit -m "feat: add ShareButton to share the sung recording via the OS share sheet"
```

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singing_feedback_mobile/widgets/playback_button.dart';

/// Fake-Implementierung von [AudioPlaybackController] fuer Tests, ganz ohne
/// echten Plattform-Kanal. [play]/[pause] koennen ueber die Completer auf
/// "haengend" gehalten werden, um Await-Race-Szenarien (Finding 1) simulieren
/// zu koennen, und optional einen Fehler werfen.
class _FakePlaybackController implements AudioPlaybackController {
  Completer<void>? playCompleter;
  Completer<void>? pauseCompleter;
  Object? throwOnPlay;
  Object? throwOnPause;
  int playCallCount = 0;
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

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('PlaybackButton Zustandsautomat (_togglePlayback)', () {
    testWidgets('Play-Tap wechselt Icon von Play zu Pause', (tester) async {
      final fake = _FakePlaybackController();
      final bytes = Uint8List.fromList([1, 2, 3]);

      await tester.pumpWidget(
        _wrap(PlaybackButton(audioBytes: bytes, controllerFactory: () => fake)),
      );

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
        'unmounted wird (Finding 1 Regressionstest)', (tester) async {
      final fake = _FakePlaybackController()..playCompleter = Completer<void>();
      final bytes = Uint8List.fromList([1, 2, 3]);

      await tester.pumpWidget(
        _wrap(PlaybackButton(audioBytes: bytes, controllerFactory: () => fake)),
      );

      await tester.tap(find.byIcon(Icons.play_arrow));
      await tester.pump(); // startet _togglePlayback, haengt in await fake.play()

      // Simuliert z.B. Wechsel von "Eigene Aufnahme" auf "MIDI-Datei" waehrend
      // die Wiedergabe noch startet: der PlaybackButton verschwindet aus dem Baum.
      await tester.pumpWidget(_wrap(const SizedBox.shrink()));

      // Jetzt loest sich das haengende play() auf, waehrend das Widget bereits
      // disposed ist. Ohne die mounted-Guards in finally/catch wuerde hier
      // "setState() called after dispose()" geworfen.
      fake.playCompleter!.complete();
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'kein setState-Fehler, wenn play() erst nach dem Unmount fehlschlaegt '
        '(catch-Zweig von Finding 1)', (tester) async {
      final fake = _FakePlaybackController()..playCompleter = Completer<void>();
      final bytes = Uint8List.fromList([1, 2, 3]);

      await tester.pumpWidget(
        _wrap(PlaybackButton(audioBytes: bytes, controllerFactory: () => fake)),
      );

      await tester.tap(find.byIcon(Icons.play_arrow));
      await tester.pump();

      await tester.pumpWidget(_wrap(const SizedBox.shrink()));

      fake.playCompleter!.completeError(Exception('Geraetefehler'));
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'Busy-Guard verhindert einen zweiten Play-Aufruf, waehrend der erste '
        'noch laeuft (Doppel-Tap)', (tester) async {
      final fake = _FakePlaybackController()..playCompleter = Completer<void>();
      final bytes = Uint8List.fromList([1, 2, 3]);

      await tester.pumpWidget(
        _wrap(PlaybackButton(audioBytes: bytes, controllerFactory: () => fake)),
      );

      await tester.tap(find.byIcon(Icons.play_arrow));
      await tester.pump();

      // Der Button ist waehrend _isBusy deaktiviert (onPressed: null), ein
      // zweiter Tap darf _togglePlayback also nicht erneut ausloesen.
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
  });
}

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
  final _positionChangedController = StreamController<Duration>.broadcast();
  final _durationChangedController = StreamController<Duration>.broadcast();

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
  Stream<Duration> get onPositionChanged => _positionChangedController.stream;

  @override
  Stream<Duration> get onDurationChanged => _durationChangedController.stream;

  @override
  void dispose() {
    disposeCallCount++;
    unawaited(_completeController.close());
    unawaited(_positionChangedController.close());
    unawaited(_durationChangedController.close());
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

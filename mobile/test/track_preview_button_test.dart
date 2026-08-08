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
import 'package:singing_feedback_mobile/widgets/track_preview_button.dart';

class _FakePreviewApiClient extends ApiClient {
  _FakePreviewApiClient() : super(baseUrl: 'http://fake.local');

  int getBytesCallCount = 0;
  Object? throwOnGetBytes;

  @override
  Future<Uint8List> getBytes(String path, {Map<String, String>? query}) async {
    getBytesCallCount++;
    if (throwOnGetBytes != null) throw throwOnGetBytes!;
    return Uint8List.fromList([1, 2, 3]);
  }
}

class _FakePlaybackController implements AudioPlaybackController {
  int playCallCount = 0;
  int pauseCallCount = 0;
  final _completeController = StreamController<void>.broadcast();
  final _positionChangedController = StreamController<Duration>.broadcast();
  final _durationChangedController = StreamController<Duration>.broadcast();

  @override
  Future<void> play(Uint8List bytes) async {
    playCallCount++;
  }

  @override
  Future<void> playFrom(Uint8List bytes, Duration position) async {}

  @override
  Future<void> pause() async {
    pauseCallCount++;
  }

  @override
  Future<void> stop() async {}

  @override
  Stream<void> get onComplete => _completeController.stream;

  @override
  Stream<Duration> get onPositionChanged => _positionChangedController.stream;

  @override
  Stream<Duration> get onDurationChanged => _durationChangedController.stream;

  @override
  void dispose() {
    unawaited(_completeController.close());
    unawaited(_positionChangedController.close());
    unawaited(_durationChangedController.close());
  }
}

SessionState _buildSession(ApiClient client, AudioPlaybackController fake) {
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
  group('TrackPreviewButton', () {
    testWidgets('Tap holt die Vorschau und startet die Wiedergabe', (tester) async {
      final client = _FakePreviewApiClient();
      final fake = _FakePlaybackController();
      final session = _buildSession(client, fake);
      session.midiSessionId = 'session-1';

      await tester.pumpWidget(_wrap(session, const TrackPreviewButton(trackIndex: 0)));

      expect(find.byIcon(Icons.play_arrow), findsOneWidget);

      await tester.tap(find.byIcon(Icons.play_arrow));
      await tester.pumpAndSettle();

      expect(client.getBytesCallCount, 1);
      expect(fake.playCallCount, 1);
      expect(find.byIcon(Icons.pause), findsOneWidget);
    });

    testWidgets('zweiter Tap auf denselben Button pausiert statt erneut zu laden',
        (tester) async {
      final client = _FakePreviewApiClient();
      final fake = _FakePlaybackController();
      final session = _buildSession(client, fake);
      session.midiSessionId = 'session-1';

      await tester.pumpWidget(_wrap(session, const TrackPreviewButton(trackIndex: 0)));
      await tester.tap(find.byIcon(Icons.play_arrow));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.pause));
      await tester.pumpAndSettle();

      expect(client.getBytesCallCount, 1);
      expect(fake.pauseCallCount, 1);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    });

    testWidgets('Fehler beim Laden zeigt eine Inline-Fehlermeldung', (tester) async {
      final client = _FakePreviewApiClient()..throwOnGetBytes = Exception('Netzwerkfehler');
      final fake = _FakePlaybackController();
      final session = _buildSession(client, fake);
      session.midiSessionId = 'session-1';

      await tester.pumpWidget(_wrap(session, const TrackPreviewButton(trackIndex: 0)));
      await tester.tap(find.byIcon(Icons.play_arrow));
      await tester.pumpAndSettle();

      expect(find.textContaining('Vorschau fehlgeschlagen'), findsOneWidget);
      expect(fake.playCallCount, 0);
    });

    testWidgets(
        'zwei TrackPreviewButton-Instanzen mit unterschiedlichem trackIndex teilen '
        'sich den Player, zeigen aber unabhaengige Icons', (tester) async {
      final client = _FakePreviewApiClient();
      final fake = _FakePlaybackController();
      final session = _buildSession(client, fake);
      session.midiSessionId = 'session-1';

      await tester.pumpWidget(_wrap(
        session,
        const Column(children: [
          TrackPreviewButton(trackIndex: 0),
          TrackPreviewButton(trackIndex: 1),
        ]),
      ));

      await tester.tap(find.byIcon(Icons.play_arrow).first);
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.pause), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    });
  });
}

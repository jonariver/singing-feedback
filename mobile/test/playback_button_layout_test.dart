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
  Stream<Duration> get onPositionChanged => const Stream.empty();

  @override
  Stream<Duration> get onDurationChanged => const Stream.empty();

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

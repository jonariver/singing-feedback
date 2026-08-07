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
import 'package:singing_feedback_mobile/models/score_result.dart';
import 'package:singing_feedback_mobile/state/session_state.dart';
import 'package:singing_feedback_mobile/widgets/feedback_section.dart';

class _FakeApiClient extends ApiClient {
  _FakeApiClient() : super(baseUrl: 'http://fake.local');

  Object? throwOnFeedback;
  Map<String, dynamic> feedbackResponse = {
    'feedback': {
      'points': [
        {
          'problem': 'Timing daneben',
          'technik': 'Testtechnik',
          'uebung': 'Testuebung',
          'wiederholungsaufgabe': null,
        },
      ],
    },
  };

  @override
  Future<Map<String, dynamic>> postJson(String path, Map<String, dynamic> body) async {
    if (throwOnFeedback != null) throw throwOnFeedback!;
    return feedbackResponse;
  }
}

class _FakePlaybackController implements AudioPlaybackController {
  int playFromCallCount = 0;
  Uint8List? lastPlayFromBytes;
  Duration? lastPlayFromPosition;
  Object? throwOnPlayFrom;

  @override
  Future<void> play(Uint8List bytes) async {}

  @override
  Future<void> playFrom(Uint8List bytes, Duration position) async {
    playFromCallCount++;
    lastPlayFromBytes = bytes;
    lastPlayFromPosition = position;
    if (throwOnPlayFrom != null) throw throwOnPlayFrom!;
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

ScoreResult _dummyScoreResult({List<String> problemTags = const ['timingprobleme']}) {
  return ScoreResult(
    notes: const [],
    summary: ScoreSummary(
      noteCount: 1,
      missedCount: 0,
      centsGreen: 1,
      centsYellow: 0,
      centsRed: 0,
      timingFlaggedCount: 1,
      stabilityFlaggedCount: 0,
      phraseEndDriftFlaggedCount: 0,
      glideFlaggedCount: 0,
      overallScore: 85.0,
      problemTags: problemTags,
      vocalRange: const VocalRange(
        applicable: false,
        minHz: null,
        maxHz: null,
        minMidiNote: null,
        maxMidiNote: null,
      ),
    ),
  );
}

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

Widget _wrap(SessionState session) {
  return ChangeNotifierProvider<SessionState>.value(
    value: session,
    child: MaterialApp(
      home: Scaffold(
        body: Consumer<SessionState>(
          builder: (context, session, _) => FeedbackSection(session: session),
        ),
      ),
    ),
  );
}

void main() {
  group('FeedbackSection', () {
    testWidgets('rendert nichts ohne scoreResult', (tester) async {
      final session = _buildSession(_FakeApiClient());
      await tester.pumpWidget(_wrap(session));
      expect(find.text('Feedback anfordern'), findsNothing);
    });

    testWidgets('Tap auf den Button zeigt nach Erfolg eine Feedback-Karte', (tester) async {
      final session = _buildSession(_FakeApiClient())..scoreResult = _dummyScoreResult();
      await tester.pumpWidget(_wrap(session));

      expect(find.text('Feedback anfordern'), findsOneWidget);
      await tester.tap(find.text('Feedback anfordern'));
      await tester.pumpAndSettle();

      expect(find.text('Timing daneben'), findsOneWidget);
      expect(find.text('Testtechnik'), findsOneWidget);
      expect(find.text('Testuebung'), findsOneWidget);
    });

    testWidgets('zeigt eine Fehlermeldung, wenn die Feedback-Anfrage fehlschlaegt', (tester) async {
      final client = _FakeApiClient()
        ..throwOnFeedback = ApiException(503, 'Feedback nicht verfuegbar.');
      final session = _buildSession(client)..scoreResult = _dummyScoreResult();
      await tester.pumpWidget(_wrap(session));

      await tester.tap(find.text('Feedback anfordern'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Feedback fehlgeschlagen'), findsOneWidget);
    });

    testWidgets('zeigt eine Hinweis-Meldung, wenn keine Punkte zurueckkommen', (tester) async {
      final client = _FakeApiClient()..feedbackResponse = {'feedback': {'points': <dynamic>[]}};
      final session = _buildSession(client)..scoreResult = _dummyScoreResult();
      await tester.pumpWidget(_wrap(session));

      await tester.tap(find.text('Feedback anfordern'));
      await tester.pumpAndSettle();

      expect(find.text('Keine besonderen Probleme erkannt.'), findsOneWidget);
    });

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

    testWidgets(
        'eine fehlgeschlagene Sprung-Anfrage bleibt nicht ueber eine neue '
        'Feedback-Runde hinweg an der gleichlautenden Kartenposition stehen '
        '(Regression: stale error + fehlender Key erlaubten State-Wiederverwendung)',
        (tester) async {
      final fakePlayback = _FakePlaybackController()
        ..throwOnPlayFrom = Exception('Geraetefehler');
      final client = _FakeApiClient()
        ..feedbackResponse = {
          'feedback': {
            'points': [
              {
                'problem': 'Erste Runde',
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

      expect(find.textContaining('Sprung fehlgeschlagen'), findsOneWidget);

      // Neue Feedback-Runde: gleiche Listenposition (Index 0), aber ein voellig
      // neues FeedbackPoint-Objekt mit anderem Inhalt - der alte Fehler darf hier
      // nicht mehr auftauchen.
      fakePlayback.throwOnPlayFrom = null;
      client.feedbackResponse = {
        'feedback': {
          'points': [
            {
              'problem': 'Zweite Runde',
              'technik': 'T2', 'uebung': 'U2',
              'wiederholungsaufgabe': null, 'jump_to_t': 3.0,
            },
          ],
        },
      };

      await tester.tap(find.text('Feedback anfordern'));
      await tester.pumpAndSettle();

      expect(find.text('Zweite Runde'), findsOneWidget);
      expect(find.textContaining('Sprung fehlgeschlagen'), findsNothing);
    });
  });
}

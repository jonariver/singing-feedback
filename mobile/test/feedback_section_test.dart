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
      overallScore: 85.0,
      problemTags: problemTags,
    ),
  );
}

SessionState _buildSession(_FakeApiClient client) {
  return SessionState(
    midiApi: MidiApi(client),
    audioApi: AudioApi(client),
    syncApi: SyncApi(client),
    scoreApi: ScoreApi(client),
    feedbackApi: FeedbackApi(client),
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
  });
}

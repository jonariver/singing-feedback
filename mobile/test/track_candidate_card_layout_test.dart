import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:singing_feedback_mobile/api/api_client.dart';
import 'package:singing_feedback_mobile/api/audio_api.dart';
import 'package:singing_feedback_mobile/api/feedback_api.dart';
import 'package:singing_feedback_mobile/api/midi_api.dart';
import 'package:singing_feedback_mobile/api/score_api.dart';
import 'package:singing_feedback_mobile/api/sync_api.dart';
import 'package:singing_feedback_mobile/models/track_candidate.dart';
import 'package:singing_feedback_mobile/state/session_state.dart';
import 'package:singing_feedback_mobile/widgets/track_candidate_card.dart';

class _FailingPreviewApiClient extends ApiClient {
  _FailingPreviewApiClient() : super(baseUrl: 'http://fake.local');

  @override
  Future<Uint8List> getBytes(String path, {Map<String, String>? query}) async {
    throw PlatformException(
      code: 'PREVIEW_ERROR',
      message: 'Die Vorschau konnte auf diesem Geraet nicht geladen werden, '
          'bitte spaeter erneut versuchen.',
    );
  }
}

TrackCandidate _longNameCandidate() {
  return TrackCandidate.fromJson({
    'index': 0,
    'name': 'Eine ziemlich lange Instrumentenspur-Bezeichnung',
    'program': 53,
    'is_drum': false,
    'note_count': 5,
    'pitch_min': 60,
    'pitch_max': 67,
    'pitch_min_name': 'C4',
    'pitch_max_name': 'G4',
    'duration_seconds': 5.0,
    'monophonic': true,
    'name_hint_match': true,
    'plausible': true,
    'score': 82.4,
    'warnings': <String>['Spur ist ueberwiegend polyphon (klingt eher nach Akkorden als nach einer Einzelstimme).'],
  });
}

void main() {
  testWidgets(
      'TrackCandidateCard mit langem Namen, Warnung und Preview-Fehlertext '
      'ueberlaeuft bei 390dp Breite nicht (RenderFlex)', (tester) async {
    final client = _FailingPreviewApiClient();
    final session = SessionState(
      midiApi: MidiApi(client),
      audioApi: AudioApi(client),
      syncApi: SyncApi(client),
      scoreApi: ScoreApi(client),
      feedbackApi: FeedbackApi(client),
    );
    session.midiSessionId = 'session-1';

    await tester.pumpWidget(
      ChangeNotifierProvider<SessionState>.value(
        value: session,
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 390,
              child: TrackCandidateCard(
                candidate: _longNameCandidate(),
                selected: false,
                onSelect: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);

    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('Vorschau fehlgeschlagen'), findsOneWidget);
  });
}

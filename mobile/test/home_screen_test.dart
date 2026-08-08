import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:singing_feedback_mobile/api/api_client.dart';
import 'package:singing_feedback_mobile/api/audio_api.dart';
import 'package:singing_feedback_mobile/api/feedback_api.dart';
import 'package:singing_feedback_mobile/api/midi_api.dart';
import 'package:singing_feedback_mobile/api/score_api.dart';
import 'package:singing_feedback_mobile/api/sync_api.dart';
import 'package:singing_feedback_mobile/screens/home_screen.dart';
import 'package:singing_feedback_mobile/state/session_state.dart';
import 'package:singing_feedback_mobile/widgets/pitch_chart.dart';

SessionState _buildSession() {
  // Ein echter ApiClient reicht hier aus - dieser Test loest keinen Tap auf einen
  // netzwerkausloesenden Button aus (Aufnahme/Upload/Bewertung/Feedback), nur
  // Header-Taps zum Ein-/Ausklappen, also wird nie tatsaechlich ein HTTP-Aufruf
  // gefeuert. Gleiches Prinzip wie die injizierbaren *Api-Klassen ueberall sonst in
  // diesem Projekt, nur ohne Fake, weil hier keine Antwort gebraucht wird.
  final client = ApiClient();
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
    child: const MaterialApp(home: HomeScreen()),
  );
}

void main() {
  testWidgets('alle fuenf Abschnitts-Titel sind initial sichtbar', (tester) async {
    await tester.pumpWidget(_wrap(_buildSession()));

    expect(find.text('1. Zielmelodie'), findsOneWidget);
    expect(find.text('2. Gesangsaufnahme'), findsOneWidget);
    expect(find.text('3. Tonhöhen-Vergleich'), findsOneWidget);
    expect(find.text('4. Bewertung'), findsOneWidget);
    expect(find.text('5. Feedback'), findsOneWidget);
  });

  testWidgets('Abschnitt 3 ist initial aufgeklappt (PitchChart sichtbar)', (tester) async {
    await tester.pumpWidget(_wrap(_buildSession()));

    expect(find.byType(PitchChart), findsOneWidget);
  });

  testWidgets(
      'Tippen auf den Titel von Abschnitt 3 klappt ihn zu - PitchChart verschwindet',
      (tester) async {
    await tester.pumpWidget(_wrap(_buildSession()));
    expect(find.byType(PitchChart), findsOneWidget);

    await tester.tap(find.text('3. Tonhöhen-Vergleich'));
    await tester.pumpAndSettle();

    expect(find.byType(PitchChart), findsNothing);
  });

  testWidgets('erneutes Tippen klappt Abschnitt 3 wieder auf - PitchChart erscheint wieder',
      (tester) async {
    await tester.pumpWidget(_wrap(_buildSession()));

    await tester.tap(find.text('3. Tonhöhen-Vergleich'));
    await tester.pumpAndSettle();
    expect(find.byType(PitchChart), findsNothing);

    await tester.tap(find.text('3. Tonhöhen-Vergleich'));
    await tester.pumpAndSettle();
    expect(find.byType(PitchChart), findsOneWidget);
  });
}

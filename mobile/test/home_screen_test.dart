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
  testWidgets('alle fuenf Abschnitts-Titel sind initial sichtbar (ggf. nach Scrollen)',
      (tester) async {
    await tester.pumpWidget(_wrap(_buildSession()));

    // Bei vollstaendig aufgeklappten Abschnitten ist der Screen laenger als
    // der Viewport - wie auf einem echten Handy muss man zu spaeteren
    // Abschnitten scrollen, um sie zu sehen. Das ist kein Test-Artefakt,
    // sondern erwartetes Verhalten einer scrollbaren ListView.
    final scrollable = find.byType(Scrollable).first;
    expect(find.text('1. Zielmelodie'), findsOneWidget);
    expect(find.text('2. Gesangsaufnahme'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('3. Tonhöhen-Vergleich'), 200,
        scrollable: scrollable);
    expect(find.text('3. Tonhöhen-Vergleich'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('4. Bewertung'), 200, scrollable: scrollable);
    expect(find.text('4. Bewertung'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('5. Feedback'), 200, scrollable: scrollable);
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

  testWidgets(
      'Abschnitt 3 bleibt zusammengeklappt, wenn er aus dem Viewport scrollt und zurueck',
      (tester) async {
    // Dies testet die PageStorageKey-Reparatur: ohne PageStorageKey wuerde
    // ein zusammengeklappter Abschnitt beim Scrollen aus dem Viewport und
    // zurueck stumm wieder aufklappen, weil der dispose/reconstruct den
    // initiallyExpanded: true Zustand reaktiviert.
    await tester.pumpWidget(_wrap(_buildSession()));
    final scrollable = find.byType(Scrollable).first;

    // Abschnitt 3 einklappen
    expect(find.byType(PitchChart), findsOneWidget);
    await tester.tap(find.text('3. Tonhöhen-Vergleich'));
    await tester.pumpAndSettle();
    expect(find.byType(PitchChart), findsNothing);

    // Zum Ende scrollen, um Abschnitt 3 weit aus dem Viewport zu scrollen
    await tester.scrollUntilVisible(find.text('5. Feedback'), 200, scrollable: scrollable);
    await tester.pumpAndSettle();

    // Zurueck zu Abschnitt 3 scrollen
    await tester.scrollUntilVisible(find.text('3. Tonhöhen-Vergleich'), -200,
        scrollable: scrollable);
    await tester.pumpAndSettle();

    // PitchChart sollte immer noch unsichtbar sein (Abschnitt 3 bleibt eingeklappt)
    expect(find.byType(PitchChart), findsNothing);
  });
}

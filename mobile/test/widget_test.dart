import 'package:flutter_test/flutter_test.dart';

import 'package:singing_feedback_mobile/main.dart';

void main() {
  testWidgets('App startet und zeigt den Home-Screen', (WidgetTester tester) async {
    await tester.pumpWidget(const SingingFeedbackApp());

    expect(find.text('Singing Feedback'), findsOneWidget);
    expect(find.text('MIDI-Datei wählen'), findsOneWidget);
  });

  testWidgets(
      'Umschalter auf Referenzaufnahme ersetzt den MIDI-Picker durch eine zweite Aufnahme-Steuerung',
      (WidgetTester tester) async {
    await tester.pumpWidget(const SingingFeedbackApp());
    expect(find.text('Aufnehmen'), findsOneWidget);

    await tester.tap(find.text('Eigene Aufnahme'));
    await tester.pumpAndSettle();

    expect(find.text('MIDI-Datei wählen'), findsNothing);
    expect(find.text('Aufnehmen'), findsNWidgets(2));
  });
}

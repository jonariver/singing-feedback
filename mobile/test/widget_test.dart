import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:singing_feedback_mobile/main.dart';

void main() {
  testWidgets('App startet direkt im Referenzaufnahme-Modus (MIDI-Zielauswahl ist fuer den Prototyp deaktiviert)',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const SingingFeedbackApp());

    expect(find.text('Singing Feedback'), findsOneWidget);
    // Zwei RecordingControl-Instanzen (Referenzaufnahme + Gesangsaufnahme) sind von
    // Anfang an im Baum, da referenceSource jetzt permanent auf recording steht -
    // RecordingControl zeigt sein "Aufnehmen"-Label immer, auch im disabled-Zustand.
    expect(find.text('Aufnehmen'), findsNWidgets(2));
    expect(find.text('MIDI-Datei wählen'), findsNothing);
  });
}

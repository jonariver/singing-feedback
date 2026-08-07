import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singing_feedback_mobile/state/session_state.dart';
import 'package:singing_feedback_mobile/widgets/status_banner.dart';

void main() {
  testWidgets('LoadStatus.warning wird orange dargestellt', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: StatusBanner(status: LoadStatus.warning, message: 'Aufnahme wurde gekürzt.'),
      ),
    ));

    final text = tester.widget<Text>(find.text('Aufnahme wurde gekürzt.'));
    expect(text.style?.color, Colors.orange.shade300);
  });

  testWidgets('LoadStatus.ok bleibt gruen (Regressionsschutz)', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: StatusBanner(status: LoadStatus.ok, message: 'Fertig.'),
      ),
    ));

    final text = tester.widget<Text>(find.text('Fertig.'));
    expect(text.style?.color, Colors.green.shade300);
  });
}

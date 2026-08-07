import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singing_feedback_mobile/models/tolerance_preset.dart';
import 'package:singing_feedback_mobile/widgets/tolerance_preset_control.dart';

void main() {
  testWidgets('zeigt alle drei Preset-Labels an', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TolerancePresetControl(value: TolerancePreset.normal, onChanged: (_) {}),
      ),
    ));

    expect(find.text('Streng'), findsOneWidget);
    expect(find.text('Normal'), findsOneWidget);
    expect(find.text('Locker'), findsOneWidget);
  });

  testWidgets('Tippen auf ein anderes Preset ruft onChanged mit dem richtigen Wert auf',
      (tester) async {
    TolerancePreset? changedTo;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TolerancePresetControl(
          value: TolerancePreset.normal,
          onChanged: (preset) => changedTo = preset,
        ),
      ),
    ));

    await tester.tap(find.text('Streng'));
    await tester.pump();

    expect(changedTo, TolerancePreset.strict);
  });
}

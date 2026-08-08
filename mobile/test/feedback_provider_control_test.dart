import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singing_feedback_mobile/models/feedback_provider.dart';
import 'package:singing_feedback_mobile/widgets/feedback_provider_control.dart';

void main() {
  testWidgets('zeigt beide Provider-Labels an', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FeedbackProviderControl(value: FeedbackProvider.anthropic, onChanged: (_) {}),
      ),
    ));

    expect(find.text('Claude'), findsOneWidget);
    expect(find.text('Cloudflare'), findsOneWidget);
  });

  testWidgets('Tippen auf einen anderen Provider ruft onChanged mit dem richtigen Wert auf',
      (tester) async {
    FeedbackProvider? changedTo;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FeedbackProviderControl(
          value: FeedbackProvider.anthropic,
          onChanged: (provider) => changedTo = provider,
        ),
      ),
    ));

    await tester.tap(find.text('Cloudflare'));
    await tester.pump();

    expect(changedTo, FeedbackProvider.cloudflare);
  });
}

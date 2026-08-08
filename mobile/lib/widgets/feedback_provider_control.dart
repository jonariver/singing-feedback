import 'package:flutter/material.dart';

import '../models/feedback_provider.dart';

/// Waehlt den Anbieter fuer die Feedback-Generierung (siehe
/// docs/superpowers/specs/2026-08-08-cloudflare-feedback-provider-design.md).
/// Reines Props-Widget (kein direkter SessionState-Zugriff), gleiches Muster
/// wie TolerancePresetControl.
class FeedbackProviderControl extends StatelessWidget {
  final FeedbackProvider value;
  final ValueChanged<FeedbackProvider> onChanged;

  const FeedbackProviderControl({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Text('Anbieter:'),
        const SizedBox(width: 12),
        SegmentedButton<FeedbackProvider>(
          segments: FeedbackProvider.values
              .map((provider) => ButtonSegment(value: provider, label: Text(provider.label)))
              .toList(),
          selected: {value},
          onSelectionChanged: (selection) => onChanged(selection.first),
        ),
      ],
    );
  }
}

import 'package:flutter/material.dart';

import '../models/tolerance_preset.dart';

/// Steuert die Toleranz fuer die gruen/gelb/rot-Klassifikation der Cent-
/// Abweichung in der Bewertung (siehe
/// docs/superpowers/specs/2026-08-07-tolerance-preset-design.md). Reines
/// Props-Widget (kein direkter SessionState-Zugriff), gleiches Muster wie
/// TransposeControl.
class TolerancePresetControl extends StatelessWidget {
  final TolerancePreset value;
  final ValueChanged<TolerancePreset> onChanged;

  const TolerancePresetControl({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Text('Toleranz:'),
        const SizedBox(width: 12),
        SegmentedButton<TolerancePreset>(
          segments: TolerancePreset.values
              .map((preset) => ButtonSegment(value: preset, label: Text(preset.label)))
              .toList(),
          selected: {value},
          onSelectionChanged: (selection) => onChanged(selection.first),
        ),
      ],
    );
  }
}

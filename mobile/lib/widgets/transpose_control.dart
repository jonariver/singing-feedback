import 'package:flutter/material.dart';

/// Ergaenzung ggue. frontend/app.js (dort ist transpose im UI hart auf 0 gesetzt),
/// nutzt aber nur den bereits vorhandenen ?transpose=N-Parameter von
/// GET /api/midi/{session_id}/track-curve.
class TransposeControl extends StatelessWidget {
  final int value;
  final ValueChanged<int> onChanged;

  const TransposeControl({super.key, required this.value, required this.onChanged});

  static const int _min = -12;
  static const int _max = 12;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Text('Transposition (Halbtöne):'),
        IconButton(
          icon: const Icon(Icons.remove),
          onPressed: value > _min ? () => onChanged(value - 1) : null,
        ),
        SizedBox(width: 32, child: Text('$value', textAlign: TextAlign.center)),
        IconButton(
          icon: const Icon(Icons.add),
          onPressed: value < _max ? () => onChanged(value + 1) : null,
        ),
      ],
    );
  }
}

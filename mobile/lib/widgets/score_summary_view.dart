import 'package:flutter/material.dart';

import '../models/score_result.dart';

const _midiNoteNames = [
  'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'B', 'H',
];

String midiNoteName(int midiNote) {
  final octave = (midiNote ~/ 12) - 1;
  final name = _midiNoteNames[midiNote % 12];
  return '$name$octave';
}

/// Einfache Text-/Zahlen-Zusammenfassung der Bewertungs-Engine (Phase 4,
/// Kernpaket). Kurvenfaerbung im Chart erfolgt in PitchChart (colorForSungPoint,
/// _drawCurve). Diese View bleibt bewusst text-only. Eine Zeile pro Note plus eine Zusammenfassungszeile.
class ScoreSummaryView extends StatelessWidget {
  final ScoreResult result;

  const ScoreSummaryView({super.key, required this.result});

  Color _classificationColor(String classification) => switch (classification) {
        'green' => Colors.green.shade300,
        'yellow' => Colors.amber.shade300,
        _ => Colors.red.shade300,
      };

  String _classificationSymbol(String classification) => switch (classification) {
        'green' => '●',
        'yellow' => '▲',
        _ => '■',
      };

  String _noteLabel(ScoreNote note) {
    final symbol = _classificationSymbol(note.centsClassification);
    final centsText = note.centsValue == null ? '–¢' : '${note.centsValue!.toStringAsFixed(0)}¢';
    final parts = <String>['$symbol $centsText'];
    if (note.timingClassification != 'on_time') {
      parts.add(note.timingClassification == 'too_early' ? 'zu früh' : 'zu spät');
    }
    if (note.phraseEndDriftFlag) {
      final direction = note.driftDirection == 'up' ? 'steigt an' : 'sackt ab';
      parts.add('Phrasenende $direction');
    }
    if (note.glideFlag) {
      final direction = note.glideDirection == 'up' ? 'von unten' : 'von oben';
      parts.add('gerutscht ($direction)');
    }
    if (note.pauseFlag) {
      final gapSeconds = note.pauseGapSeconds;
      parts.add(gapSeconds == null
          ? 'Pause mitten in der Note'
          : 'Pause mitten in der Note (${gapSeconds.toStringAsFixed(2)}s)');
    }
    if (note.stabilityFlag) parts.add('instabil');
    if (note.missed) parts.add('verfehlt');
    return 'Note ${note.index + 1}: ${parts.join(' · ')}';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final note in result.notes)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(
              _noteLabel(note),
              style: TextStyle(color: _classificationColor(note.centsClassification)),
            ),
          ),
        const SizedBox(height: 8),
        Text(
          '${result.summary.missedCount} verfehlt · ${result.summary.centsYellow} gelb · '
          '${result.summary.centsRed} rot · Gesamt: ${result.summary.overallScore.toStringAsFixed(0)}',
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        if (result.summary.vocalRange.applicable)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Stimmumfang: '
              '${midiNoteName(result.summary.vocalRange.minMidiNote!)}'
              '–${midiNoteName(result.summary.vocalRange.maxMidiNote!)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

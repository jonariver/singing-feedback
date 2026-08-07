import 'package:flutter/material.dart';

import '../models/track_candidate.dart';
import 'track_preview_button.dart';

/// Farbcodierung des 0-100 Heuristik-Scores, identisch zum bestehenden
/// Gruen/Gelb/Rot-Schema aus PitchChart/ScoreSummaryView.
Color trackScoreColor(double score) {
  if (score >= 70) return Colors.green.shade300;
  if (score >= 40) return Colors.amber.shade300;
  return Colors.red.shade300;
}

/// Entspricht renderTrackList() in frontend/app.js: Name, Notenzahl, Tonumfang,
/// Dauer, monophon/polyphon, Namenstreffer-Hinweis und Warnungen pro Kandidat.
class TrackCandidateCard extends StatelessWidget {
  final TrackCandidate candidate;
  final bool selected;
  final VoidCallback? onSelect;

  const TrackCandidateCard({
    super.key,
    required this.candidate,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final meta = 'Noten: ${candidate.noteCount} · Tonumfang: ${candidate.rangeLabel} · '
        'Dauer: ${candidate.durationSeconds}s · '
        '${candidate.monophonic ? "monophon" : "polyphon"}'
        '${candidate.nameHintMatch ? " · Namenstreffer" : ""}';

    return Card(
      color: selected ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.15) : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(candidate.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: trackScoreColor(candidate.score).withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${candidate.score.round()}%',
                    style: TextStyle(
                      color: trackScoreColor(candidate.score),
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(meta, style: Theme.of(context).textTheme.bodySmall),
            if (candidate.warnings.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                candidate.warnings.join(' '),
                style: TextStyle(color: Colors.orange.shade300, fontSize: 12),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: candidate.noteCount == 0 ? null : onSelect,
                    child: const Text('Auswählen'),
                  ),
                ),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 140),
                  child: TrackPreviewButton(trackIndex: candidate.index),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

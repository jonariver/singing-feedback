import 'package:flutter/material.dart';

import '../models/track_candidate.dart';

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
      color: selected ? Colors.blue.shade50 : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(candidate.name, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(meta, style: Theme.of(context).textTheme.bodySmall),
            if (candidate.warnings.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                candidate.warnings.join(' '),
                style: TextStyle(color: Colors.orange.shade800, fontSize: 12),
              ),
            ],
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: candidate.noteCount == 0 ? null : onSelect,
              child: const Text('Auswählen & anhören'),
            ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../models/feedback_result.dart';
import '../state/session_state.dart';

/// Abschnitt "5. Feedback": Button "Feedback anfordern" (kein Auto-Trigger, jeder
/// Aufruf loest eine echte, kostenpflichtige Anthropic-API-Anfrage aus) plus bis
/// zu drei Feedback-Karten nach erfolgreichem Aufruf. Rendert nichts, solange
/// keine Bewertung vorliegt. Anders als PlaybackButton/ShareButton kein eigener
/// injizierbarer Controller noetig: der HTTP-Aufruf laeuft zentral ueber
/// SessionState.requestFeedback() (wie score()/align()), Ladezustand/Fehler
/// kommen aus session.feedbackStatus/feedbackMessage.
class FeedbackSection extends StatelessWidget {
  final SessionState session;

  const FeedbackSection({super.key, required this.session});

  @override
  Widget build(BuildContext context) {
    if (session.scoreResult == null) return const SizedBox.shrink();
    final isLoading = session.feedbackStatus == LoadStatus.loading;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ElevatedButton(
          onPressed: isLoading ? null : session.requestFeedback,
          child: Text(isLoading ? 'Hole Feedback…' : 'Feedback anfordern'),
        ),
        if (session.feedbackStatus == LoadStatus.error)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              session.feedbackMessage,
              style: TextStyle(color: Colors.red.shade300, fontSize: 12),
            ),
          ),
        if (session.feedbackResult != null && session.feedbackResult!.points.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('Keine besonderen Probleme erkannt.'),
          ),
        if (session.feedbackResult != null)
          for (final point in session.feedbackResult!.points) _FeedbackPointCard(point: point),
      ],
    );
  }
}

class _FeedbackPointCard extends StatelessWidget {
  final FeedbackPoint point;

  const _FeedbackPointCard({required this.point});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(point.problem, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(point.technik),
            const SizedBox(height: 4),
            Text(point.uebung),
            if (point.wiederholungsaufgabe != null) ...[
              const SizedBox(height: 4),
              Text('Wiederholung: ${point.wiederholungsaufgabe}'),
            ],
          ],
        ),
      ),
    );
  }
}

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
          for (final point in session.feedbackResult!.points)
            _FeedbackPointCard(point: point, session: session),
      ],
    );
  }
}

class _FeedbackPointCard extends StatefulWidget {
  final FeedbackPoint point;
  final SessionState session;

  const _FeedbackPointCard({required this.point, required this.session});

  @override
  State<_FeedbackPointCard> createState() => _FeedbackPointCardState();
}

class _FeedbackPointCardState extends State<_FeedbackPointCard> {
  bool _isBusy = false;
  String? _errorMessage;

  /// Startet die Wiedergabe der eigenen Aufnahme an der zur Karte gehoerenden
  /// Zeitstelle, mit 0,5s Vorlauf (max(0, jumpToT - 0.5)) - damit auch der
  /// Ansatz des bereits angesungenen Tons zu hoeren ist, nicht nur der Ton
  /// selbst. Der Vorlauf wird bewusst hier (mobile-seitig) angewendet, nicht im
  /// Backend - jump_to_t bleibt der reine Notenbeginn.
  Future<void> _jumpToPosition() async {
    final jumpToT = widget.point.jumpToT;
    final audioBytes = widget.session.sungAudioBytes;
    if (_isBusy || jumpToT == null || audioBytes == null) return;
    setState(() => _isBusy = true);
    try {
      final startSeconds = jumpToT - 0.5 < 0 ? 0.0 : jumpToT - 0.5;
      await widget.session.playFrom(
        audioBytes,
        Duration(milliseconds: (startSeconds * 1000).round()),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = 'Sprung fehlgeschlagen: $e');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final point = widget.point;
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(point.problem, style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
                if (point.jumpToT != null)
                  IconButton(
                    onPressed: _isBusy ? null : _jumpToPosition,
                    icon: const Icon(Icons.play_circle_outline),
                    tooltip: 'Zur Stelle springen',
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(point.technik),
            const SizedBox(height: 4),
            Text(point.uebung),
            if (point.wiederholungsaufgabe != null) ...[
              const SizedBox(height: 4),
              Text('Wiederholung: ${point.wiederholungsaufgabe}'),
            ],
            if (_errorMessage != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _errorMessage!,
                  style: TextStyle(color: Colors.red.shade300, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

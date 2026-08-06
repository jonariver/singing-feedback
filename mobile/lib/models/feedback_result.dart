/// Ergebnis von POST /api/feedback (backend/api/routes.py::feedback), siehe
/// docs/superpowers/specs/2026-08-06-claude-feedback-design.md.
class FeedbackPoint {
  final String problem;
  final String technik;
  final String uebung;
  final String? wiederholungsaufgabe;

  const FeedbackPoint({
    required this.problem,
    required this.technik,
    required this.uebung,
    required this.wiederholungsaufgabe,
  });

  factory FeedbackPoint.fromJson(Map<String, dynamic> json) => FeedbackPoint(
        problem: json['problem'] as String,
        technik: json['technik'] as String,
        uebung: json['uebung'] as String,
        wiederholungsaufgabe: json['wiederholungsaufgabe'] as String?,
      );
}

class FeedbackResult {
  final List<FeedbackPoint> points;

  const FeedbackResult({required this.points});

  factory FeedbackResult.fromJson(Map<String, dynamic> json) => FeedbackResult(
        points: (json['points'] as List)
            .cast<Map<String, dynamic>>()
            .map(FeedbackPoint.fromJson)
            .toList(),
      );
}

import '../models/feedback_provider.dart';
import '../models/feedback_result.dart';
import 'api_client.dart';

/// Ruft POST /api/feedback auf (backend/api/routes.py::feedback) und liefert das
/// geparste Feedback. Nimmt das bereits vom Server erhaltene ScoreResult-JSON
/// entgegen (via ScoreResult.toJson()) - keine Neuberechnung noetig.
class FeedbackApi {
  final ApiClient _client;

  FeedbackApi(this._client);

  Future<FeedbackResult> requestFeedback(
    Map<String, dynamic> scoreJson,
    FeedbackProvider provider,
  ) async {
    final json = await _client.postJson(
      '/api/feedback',
      {'score': scoreJson, 'provider': provider.apiValue},
    );
    return FeedbackResult.fromJson(json['feedback'] as Map<String, dynamic>);
  }
}

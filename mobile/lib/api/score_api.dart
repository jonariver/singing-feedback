import '../models/score_result.dart';
import '../models/sung_point.dart';
import 'api_client.dart';

/// Ruft POST /api/score auf (backend/api/routes.py::score) und liefert das
/// geparste Bewertungsergebnis. Nimmt die Zielkurve als bereits serialisiertes
/// JSON entgegen (nicht als TargetPoint-Liste), da der Aufrufer je nach Modus
/// entweder TargetPoint- oder SungPoint-Objekte serialisiert (siehe SessionState.score()).
class ScoreApi {
  final ApiClient _client;

  ScoreApi(this._client);

  Future<ScoreResult> score(
    List<Map<String, dynamic>> targetCurveJson,
    List<SungPoint> alignedSungCurve,
  ) async {
    final json = await _client.postJson('/api/score', {
      'target_curve': targetCurveJson,
      'sung_curve': alignedSungCurve.map((p) => p.toJson()).toList(),
    });
    return ScoreResult.fromJson(json['score'] as Map<String, dynamic>);
  }
}

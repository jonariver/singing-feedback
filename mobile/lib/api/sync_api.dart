import 'dart:typed_data';

import '../models/sung_point.dart';
import 'api_client.dart';

/// Ruft POST /api/sync/align auf (backend/api/routes.py::sync_align) und liefert
/// die gesungene Kurve mit aligned_t pro Frame zurueck. target_curve/target_duration
/// aus der Antwort werden bewusst nicht geparst - der Client hat die Zielkurve
/// bereits unabhaengig ueber MidiApi/analyzeReference geladen.
class SyncApi {
  final ApiClient _client;

  SyncApi(this._client);

  Future<List<SungPoint>> alignWithMidi(
    Uint8List sungBytes,
    String sungFilename, {
    required String sessionId,
    required int trackIndex,
    int transpose = 0,
  }) async {
    final json = await _client.postMultipart(
      '/api/sync/align',
      fieldName: 'sung_audio',
      bytes: sungBytes,
      filename: sungFilename,
      fields: {
        'session_id': sessionId,
        'track_index': trackIndex.toString(),
        'transpose': transpose.toString(),
      },
    );
    return _parseSungCurve(json);
  }

  Future<List<SungPoint>> alignWithReference(
    Uint8List sungBytes,
    String sungFilename,
    Uint8List referenceBytes,
    String referenceFilename,
  ) async {
    final json = await _client.postMultipart(
      '/api/sync/align',
      fieldName: 'sung_audio',
      bytes: sungBytes,
      filename: sungFilename,
      secondFieldName: 'reference_audio',
      secondBytes: referenceBytes,
      secondFilename: referenceFilename,
    );
    return _parseSungCurve(json);
  }

  List<SungPoint> _parseSungCurve(Map<String, dynamic> json) {
    final curve = (json['sung_curve'] as List).cast<Map<String, dynamic>>();
    return curve.map(SungPoint.fromJson).toList();
  }
}

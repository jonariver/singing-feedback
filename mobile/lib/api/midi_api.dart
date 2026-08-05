import 'dart:typed_data';

import '../models/midi_upload_result.dart';
import '../models/target_point.dart';
import 'api_client.dart';

class MidiApi {
  final ApiClient _client;

  MidiApi(this._client);

  Future<MidiUploadResult> uploadMidi(Uint8List bytes, String filename) async {
    final json = await _client.postMultipart(
      '/api/midi/upload',
      fieldName: 'file',
      bytes: bytes,
      filename: filename,
    );
    return MidiUploadResult.fromJson(json);
  }

  Future<List<TargetPoint>> getTrackCurve(
    String sessionId,
    int trackIndex, {
    int transpose = 0,
  }) async {
    final json = await _client.get(
      '/api/midi/$sessionId/track-curve',
      query: {
        'track_index': trackIndex.toString(),
        'transpose': transpose.toString(),
      },
    );
    final curve = (json['curve'] as List).cast<Map<String, dynamic>>();
    return curve.map(TargetPoint.fromJson).toList();
  }

  Future<void> deleteSession(String sessionId) {
    return _client.delete('/api/midi/$sessionId');
  }
}

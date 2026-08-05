import 'dart:typed_data';

import '../models/sung_point.dart';
import 'api_client.dart';

class AudioApi {
  final ApiClient _client;

  AudioApi(this._client);

  Future<List<SungPoint>> analyzeAudio(Uint8List bytes, String filename) async {
    final json = await _client.postMultipart(
      '/api/audio/analyze',
      fieldName: 'file',
      bytes: bytes,
      filename: filename,
    );
    final curve = (json['curve'] as List).cast<Map<String, dynamic>>();
    return curve.map(SungPoint.fromJson).toList();
  }
}

import 'dart:typed_data';

import '../models/audio_analysis_result.dart';
import 'api_client.dart';

class AudioApi {
  final ApiClient _client;

  AudioApi(this._client);

  Future<AudioAnalysisResult> analyzeAudio(Uint8List bytes, String filename) async {
    final json = await _client.postMultipart(
      '/api/audio/analyze',
      fieldName: 'file',
      bytes: bytes,
      filename: filename,
    );
    return AudioAnalysisResult.fromJson(json);
  }
}

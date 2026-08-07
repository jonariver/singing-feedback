import 'sung_point.dart';

/// Ergebnis von POST /api/audio/analyze. `truncated`/`originalDurationSeconds`
/// spiegeln backend/pitch_detection/pyin.py::analyze_pitch()s Rueckgabe - siehe
/// docs/superpowers/specs/2026-08-07-longer-recordings-design.md.
class AudioAnalysisResult {
  final List<SungPoint> curve;
  final bool truncated;
  final double originalDurationSeconds;

  const AudioAnalysisResult({
    required this.curve,
    required this.truncated,
    required this.originalDurationSeconds,
  });

  factory AudioAnalysisResult.fromJson(Map<String, dynamic> json) {
    final curve = (json['curve'] as List).cast<Map<String, dynamic>>();
    return AudioAnalysisResult(
      curve: curve.map(SungPoint.fromJson).toList(),
      truncated: json['truncated'] as bool,
      originalDurationSeconds: (json['original_duration_seconds'] as num).toDouble(),
    );
  }
}

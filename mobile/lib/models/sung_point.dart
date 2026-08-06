/// Ein Punkt der gesungenen Pitch-Kurve, wie sie analyze_pitch() in
/// backend/pitch_detection/pyin.py liefert. hz ist null bei unstimmhaften/stillen
/// Abschnitten (Pausen, Atmen, Konsonanten) - dort gilt voiced == false.
///
/// alignedT ist null, bis /api/sync/align erfolgreich war - dann die per DTW
/// ermittelte Zielzeit dieses Frames (siehe backend/sync/align.py).
class SungPoint {
  final double t;
  final double? hz;
  final bool voiced;
  final double confidence;
  final double? alignedT;

  const SungPoint({
    required this.t,
    required this.hz,
    required this.voiced,
    required this.confidence,
    this.alignedT,
  });

  factory SungPoint.fromJson(Map<String, dynamic> json) {
    return SungPoint(
      t: (json['t'] as num).toDouble(),
      hz: (json['hz'] as num?)?.toDouble(),
      voiced: json['voiced'] as bool,
      confidence: (json['confidence'] as num).toDouble(),
      alignedT: (json['aligned_t'] as num?)?.toDouble(),
    );
  }
}

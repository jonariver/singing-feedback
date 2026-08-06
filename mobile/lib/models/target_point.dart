/// Ein Punkt der MIDI-Zielkurve, wie sie track_pitch_curve() in
/// backend/midi_analysis/parser.py liefert. hz/midiNote sind null waehrend Pausen.
class TargetPoint {
  final double t;
  final double? hz;
  final int? midiNote;

  const TargetPoint({required this.t, required this.hz, required this.midiNote});

  factory TargetPoint.fromJson(Map<String, dynamic> json) {
    return TargetPoint(
      t: (json['t'] as num).toDouble(),
      hz: (json['hz'] as num?)?.toDouble(),
      midiNote: json['midi_note'] as int?,
    );
  }

  Map<String, dynamic> toJson() => {'t': t, 'hz': hz, 'midi_note': midiNote};
}

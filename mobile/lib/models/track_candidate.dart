/// Spiegelt TrackCandidate.to_dict() aus backend/midi_analysis/parser.py.
class TrackCandidate {
  final int index;
  final String name;
  final int program;
  final bool isDrum;
  final int noteCount;
  final int? pitchMin;
  final int? pitchMax;
  final String? pitchMinName;
  final String? pitchMaxName;
  final double durationSeconds;
  final bool monophonic;
  final bool nameHintMatch;
  final bool plausible;
  final List<String> warnings;

  const TrackCandidate({
    required this.index,
    required this.name,
    required this.program,
    required this.isDrum,
    required this.noteCount,
    required this.pitchMin,
    required this.pitchMax,
    required this.pitchMinName,
    required this.pitchMaxName,
    required this.durationSeconds,
    required this.monophonic,
    required this.nameHintMatch,
    required this.plausible,
    required this.warnings,
  });

  factory TrackCandidate.fromJson(Map<String, dynamic> json) {
    return TrackCandidate(
      index: json['index'] as int,
      name: json['name'] as String,
      program: json['program'] as int,
      isDrum: json['is_drum'] as bool,
      noteCount: json['note_count'] as int,
      pitchMin: json['pitch_min'] as int?,
      pitchMax: json['pitch_max'] as int?,
      pitchMinName: json['pitch_min_name'] as String?,
      pitchMaxName: json['pitch_max_name'] as String?,
      durationSeconds: (json['duration_seconds'] as num).toDouble(),
      monophonic: json['monophonic'] as bool,
      nameHintMatch: json['name_hint_match'] as bool,
      plausible: json['plausible'] as bool,
      warnings: (json['warnings'] as List).map((w) => w.toString()).toList(),
    );
  }

  String get rangeLabel =>
      (pitchMinName != null && pitchMaxName != null) ? '$pitchMinName–$pitchMaxName' : '–';
}

/// Ergebnis von POST /api/score (backend/scoring/score.py::score_performance),
/// siehe docs/superpowers/specs/2026-08-06-scoring-engine-design.md fuer das
/// vollstaendige JSON-Schema.
class ScoreNote {
  final int index;
  final double startT;
  final double endT;
  final double? targetHz;
  final int? targetMidiNote;
  final bool missed;
  final double coverageFraction;
  final double? centsValue;
  final String centsClassification;
  final double? timingDeviationMs;
  final String timingClassification;
  final bool held;
  final bool stabilityApplicable;
  final double? stabilityMadCents;
  final bool stabilityFlag;
  final bool driftApplicable;
  final double? driftCents;
  final bool phraseEndDriftFlag;
  final String? driftDirection;

  const ScoreNote({
    required this.index,
    required this.startT,
    required this.endT,
    required this.targetHz,
    required this.targetMidiNote,
    required this.missed,
    required this.coverageFraction,
    required this.centsValue,
    required this.centsClassification,
    required this.timingDeviationMs,
    required this.timingClassification,
    required this.held,
    required this.stabilityApplicable,
    required this.stabilityMadCents,
    required this.stabilityFlag,
    required this.driftApplicable,
    required this.driftCents,
    required this.phraseEndDriftFlag,
    required this.driftDirection,
  });

  factory ScoreNote.fromJson(Map<String, dynamic> json) {
    final cents = json['cents_deviation'] as Map<String, dynamic>;
    final timing = json['timing'] as Map<String, dynamic>;
    final stability = json['stability'] as Map<String, dynamic>;
    final drift = json['phrase_end_drift'] as Map<String, dynamic>;
    return ScoreNote(
      index: json['index'] as int,
      startT: (json['start_t'] as num).toDouble(),
      endT: (json['end_t'] as num).toDouble(),
      targetHz: (json['target_hz'] as num?)?.toDouble(),
      targetMidiNote: json['target_midi_note'] as int?,
      missed: json['missed'] as bool,
      coverageFraction: (json['coverage_fraction'] as num).toDouble(),
      centsValue: (cents['value'] as num?)?.toDouble(),
      centsClassification: cents['classification'] as String,
      timingDeviationMs: (timing['deviation_ms'] as num?)?.toDouble(),
      timingClassification: timing['classification'] as String,
      held: json['held'] as bool,
      stabilityApplicable: stability['applicable'] as bool,
      stabilityMadCents: (stability['mad_cents'] as num?)?.toDouble(),
      stabilityFlag: stability['flag'] as bool,
      driftApplicable: drift['applicable'] as bool,
      driftCents: (drift['drift_cents'] as num?)?.toDouble(),
      phraseEndDriftFlag: drift['flag'] as bool,
      driftDirection: drift['direction'] as String?,
    );
  }
}

class ScoreSummary {
  final int noteCount;
  final int missedCount;
  final int centsGreen;
  final int centsYellow;
  final int centsRed;
  final int timingFlaggedCount;
  final int stabilityFlaggedCount;
  final int phraseEndDriftFlaggedCount;
  final double overallScore;
  final List<String> problemTags;

  const ScoreSummary({
    required this.noteCount,
    required this.missedCount,
    required this.centsGreen,
    required this.centsYellow,
    required this.centsRed,
    required this.timingFlaggedCount,
    required this.stabilityFlaggedCount,
    required this.phraseEndDriftFlaggedCount,
    required this.overallScore,
    required this.problemTags,
  });

  factory ScoreSummary.fromJson(Map<String, dynamic> json) => ScoreSummary(
        noteCount: json['note_count'] as int,
        missedCount: json['missed_count'] as int,
        centsGreen: json['cents_green'] as int,
        centsYellow: json['cents_yellow'] as int,
        centsRed: json['cents_red'] as int,
        timingFlaggedCount: json['timing_flagged_count'] as int,
        stabilityFlaggedCount: json['stability_flagged_count'] as int,
        phraseEndDriftFlaggedCount: json['phrase_end_drift_flagged_count'] as int,
        overallScore: (json['overall_score'] as num).toDouble(),
        problemTags: (json['problem_tags'] as List).cast<String>(),
      );
}

class ScoreResult {
  final List<ScoreNote> notes;
  final ScoreSummary summary;

  const ScoreResult({required this.notes, required this.summary});

  factory ScoreResult.fromJson(Map<String, dynamic> json) => ScoreResult(
        notes: (json['notes'] as List)
            .cast<Map<String, dynamic>>()
            .map(ScoreNote.fromJson)
            .toList(),
        summary: ScoreSummary.fromJson(json['summary'] as Map<String, dynamic>),
      );
}

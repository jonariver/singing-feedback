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
  final bool glideApplicable;
  final double? glideOnsetCentsDeviation;
  final bool glideFlag;
  final String? glideDirection;
  final double? sungT;

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
    required this.glideApplicable,
    required this.glideOnsetCentsDeviation,
    required this.glideFlag,
    required this.glideDirection,
    required this.sungT,
  });

  factory ScoreNote.fromJson(Map<String, dynamic> json) {
    final cents = json['cents_deviation'] as Map<String, dynamic>;
    final timing = json['timing'] as Map<String, dynamic>;
    final stability = json['stability'] as Map<String, dynamic>;
    final drift = json['phrase_end_drift'] as Map<String, dynamic>;
    final glide = json['glide'] as Map<String, dynamic>;
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
      glideApplicable: glide['applicable'] as bool,
      glideOnsetCentsDeviation: (glide['onset_cents_deviation'] as num?)?.toDouble(),
      glideFlag: glide['flag'] as bool,
      glideDirection: glide['direction'] as String?,
      sungT: (json['sung_t'] as num?)?.toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
        'index': index,
        'start_t': startT,
        'end_t': endT,
        'target_hz': targetHz,
        'target_midi_note': targetMidiNote,
        'missed': missed,
        'coverage_fraction': coverageFraction,
        'cents_deviation': {'value': centsValue, 'classification': centsClassification},
        'timing': {'deviation_ms': timingDeviationMs, 'classification': timingClassification},
        'held': held,
        'stability': {
          'applicable': stabilityApplicable,
          'mad_cents': stabilityMadCents,
          'flag': stabilityFlag,
        },
        'phrase_end_drift': {
          'applicable': driftApplicable,
          'drift_cents': driftCents,
          'flag': phraseEndDriftFlag,
          'direction': driftDirection,
        },
        'glide': {
          'applicable': glideApplicable,
          'onset_cents_deviation': glideOnsetCentsDeviation,
          'flag': glideFlag,
          'direction': glideDirection,
        },
        'sung_t': sungT,
      };
}

class VocalRange {
  final bool applicable;
  final double? minHz;
  final double? maxHz;
  final int? minMidiNote;
  final int? maxMidiNote;

  const VocalRange({
    required this.applicable,
    required this.minHz,
    required this.maxHz,
    required this.minMidiNote,
    required this.maxMidiNote,
  });

  factory VocalRange.fromJson(Map<String, dynamic> json) => VocalRange(
        applicable: json['applicable'] as bool,
        minHz: (json['min_hz'] as num?)?.toDouble(),
        maxHz: (json['max_hz'] as num?)?.toDouble(),
        minMidiNote: json['min_midi_note'] as int?,
        maxMidiNote: json['max_midi_note'] as int?,
      );

  Map<String, dynamic> toJson() => {
        'applicable': applicable,
        'min_hz': minHz,
        'max_hz': maxHz,
        'min_midi_note': minMidiNote,
        'max_midi_note': maxMidiNote,
      };
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
  final int glideFlaggedCount;
  final double overallScore;
  final List<String> problemTags;
  final VocalRange vocalRange;

  const ScoreSummary({
    required this.noteCount,
    required this.missedCount,
    required this.centsGreen,
    required this.centsYellow,
    required this.centsRed,
    required this.timingFlaggedCount,
    required this.stabilityFlaggedCount,
    required this.phraseEndDriftFlaggedCount,
    required this.glideFlaggedCount,
    required this.overallScore,
    required this.problemTags,
    required this.vocalRange,
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
        glideFlaggedCount: json['glide_flagged_count'] as int,
        overallScore: (json['overall_score'] as num).toDouble(),
        problemTags: (json['problem_tags'] as List).cast<String>(),
        vocalRange: VocalRange.fromJson(json['vocal_range'] as Map<String, dynamic>),
      );

  Map<String, dynamic> toJson() => {
        'note_count': noteCount,
        'missed_count': missedCount,
        'cents_green': centsGreen,
        'cents_yellow': centsYellow,
        'cents_red': centsRed,
        'timing_flagged_count': timingFlaggedCount,
        'stability_flagged_count': stabilityFlaggedCount,
        'phrase_end_drift_flagged_count': phraseEndDriftFlaggedCount,
        'glide_flagged_count': glideFlaggedCount,
        'overall_score': overallScore,
        'problem_tags': problemTags,
        'vocal_range': vocalRange.toJson(),
      };
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

  Map<String, dynamic> toJson() => {
        'notes': notes.map((n) => n.toJson()).toList(),
        'summary': summary.toJson(),
      };
}

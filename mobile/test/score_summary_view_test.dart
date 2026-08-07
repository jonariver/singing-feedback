import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singing_feedback_mobile/models/score_result.dart';
import 'package:singing_feedback_mobile/widgets/score_summary_view.dart';

ScoreNote _glideNote({required String direction}) {
  return ScoreNote(
    index: 0,
    startT: 0.0,
    endT: 1.0,
    targetHz: 440.0,
    targetMidiNote: 69,
    missed: false,
    coverageFraction: 1.0,
    centsValue: 2.0,
    centsClassification: 'green',
    timingDeviationMs: 4.0,
    timingClassification: 'on_time',
    held: true,
    stabilityApplicable: true,
    stabilityMadCents: 0.5,
    stabilityFlag: false,
    driftApplicable: true,
    driftCents: 0.2,
    phraseEndDriftFlag: false,
    driftDirection: null,
    glideApplicable: true,
    glideOnsetCentsDeviation: -62.0,
    glideFlag: true,
    glideDirection: direction,
    sungT: 0.1,
  );
}

ScoreResult _resultWith(ScoreNote note) {
  return ScoreResult(
    notes: [note],
    summary: const ScoreSummary(
      noteCount: 1,
      missedCount: 0,
      centsGreen: 1,
      centsYellow: 0,
      centsRed: 0,
      timingFlaggedCount: 0,
      stabilityFlaggedCount: 0,
      phraseEndDriftFlaggedCount: 0,
      glideFlaggedCount: 1,
      overallScore: 100.0,
      problemTags: [],
      vocalRange: VocalRange(
        applicable: false,
        minHz: null,
        maxHz: null,
        minMidiNote: null,
        maxMidiNote: null,
      ),
    ),
  );
}

ScoreResult _resultWithVocalRange(VocalRange vocalRange) {
  return ScoreResult(
    notes: const [],
    summary: ScoreSummary(
      noteCount: 0,
      missedCount: 0,
      centsGreen: 0,
      centsYellow: 0,
      centsRed: 0,
      timingFlaggedCount: 0,
      stabilityFlaggedCount: 0,
      phraseEndDriftFlaggedCount: 0,
      glideFlaggedCount: 0,
      overallScore: 100.0,
      problemTags: const [],
      vocalRange: vocalRange,
    ),
  );
}

void main() {
  testWidgets('zeigt "gerutscht (von unten)" fuer eine Note mit Glide von unten',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ScoreSummaryView(result: _resultWith(_glideNote(direction: 'up')))),
    ));
    expect(find.textContaining('gerutscht (von unten)'), findsOneWidget);
  });

  testWidgets('zeigt "gerutscht (von oben)" fuer eine Note mit Glide von oben',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ScoreSummaryView(result: _resultWith(_glideNote(direction: 'down')))),
    ));
    expect(find.textContaining('gerutscht (von oben)'), findsOneWidget);
  });

  testWidgets('zeigt Stimmumfang, wenn vocalRange.applicable true ist', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ScoreSummaryView(
          result: _resultWithVocalRange(const VocalRange(
            applicable: true,
            minHz: 196.5,
            maxHz: 587.3,
            minMidiNote: 55,
            maxMidiNote: 74,
          )),
        ),
      ),
    ));
    expect(find.textContaining('Stimmumfang: G3–D5'), findsOneWidget);
  });

  testWidgets('zeigt keinen Stimmumfang-Hinweis, wenn vocalRange.applicable false ist',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ScoreSummaryView(
          result: _resultWithVocalRange(const VocalRange(
            applicable: false,
            minHz: null,
            maxHz: null,
            minMidiNote: null,
            maxMidiNote: null,
          )),
        ),
      ),
    ));
    expect(find.textContaining('Stimmumfang'), findsNothing);
  });

  test('midiNoteName formatiert C4/A4 korrekt', () {
    expect(midiNoteName(60), 'C4');
    expect(midiNoteName(69), 'A4');
  });

  test('midiNoteName behandelt Oktavgrenzen korrekt', () {
    expect(midiNoteName(59), 'H3');
    expect(midiNoteName(72), 'C5');
  });
}

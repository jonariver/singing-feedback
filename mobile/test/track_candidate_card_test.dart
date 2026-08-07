import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:singing_feedback_mobile/models/track_candidate.dart';
import 'package:singing_feedback_mobile/widgets/track_candidate_card.dart';

TrackCandidate _candidateWithScore(double score) {
  return TrackCandidate.fromJson({
    'index': 0,
    'name': 'Vocal',
    'program': 53,
    'is_drum': false,
    'note_count': 5,
    'pitch_min': 60,
    'pitch_max': 67,
    'pitch_min_name': 'C4',
    'pitch_max_name': 'G4',
    'duration_seconds': 5.0,
    'monophonic': true,
    'name_hint_match': true,
    'plausible': true,
    'score': score,
    'warnings': <String>[],
  });
}

void main() {
  group('TrackCandidate.fromJson', () {
    test('parst das score-Feld aus der Backend-Antwort', () {
      final candidate = _candidateWithScore(78.5);
      expect(candidate.score, 78.5);
    });
  });

  group('trackScoreColor', () {
    test('Score >= 70 ist gruen', () {
      expect(trackScoreColor(70.0), Colors.green.shade300);
      expect(trackScoreColor(100.0), Colors.green.shade300);
    });

    test('Score zwischen 40 und 70 (exklusiv) ist gelb', () {
      expect(trackScoreColor(40.0), Colors.amber.shade300);
      expect(trackScoreColor(69.9), Colors.amber.shade300);
    });

    test('Score unter 40 ist rot', () {
      expect(trackScoreColor(39.9), Colors.red.shade300);
      expect(trackScoreColor(0.0), Colors.red.shade300);
    });
  });
}

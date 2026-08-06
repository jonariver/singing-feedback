import 'package:flutter_test/flutter_test.dart';
import 'package:singing_feedback_mobile/models/score_result.dart';

Map<String, dynamic> _noteJson() => {
      'index': 0, 'start_t': 0.0, 'end_t': 1.0,
      'target_hz': 440.0, 'target_midi_note': 69,
      'missed': false, 'coverage_fraction': 1.0,
      'cents_deviation': {'value': 1.2, 'classification': 'green'},
      'timing': {'deviation_ms': 4.0, 'classification': 'on_time'},
      'held': true,
      'stability': {'applicable': true, 'mad_cents': 0.8, 'flag': false},
      'phrase_end_drift': {'applicable': true, 'drift_cents': 0.3, 'flag': false, 'direction': null},
      'sung_t': 0.12,
    };

Map<String, dynamic> _resultJson() => {
      'notes': [_noteJson()],
      'summary': {
        'note_count': 1, 'missed_count': 0,
        'cents_green': 1, 'cents_yellow': 0, 'cents_red': 0,
        'timing_flagged_count': 0, 'stability_flagged_count': 0,
        'phrase_end_drift_flagged_count': 0,
        'overall_score': 100.0,
        'problem_tags': <String>[],
      },
    };

void main() {
  test('ScoreResult.toJson() ist die Umkehrung von ScoreResult.fromJson()', () {
    final original = _resultJson();
    final result = ScoreResult.fromJson(original);
    expect(result.toJson(), original);
  });
}

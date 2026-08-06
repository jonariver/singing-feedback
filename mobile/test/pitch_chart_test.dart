import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singing_feedback_mobile/widgets/pitch_chart.dart';

// Entspricht _sungColor in pitch_chart.dart (privat, daher hier als eigene
// Konstante fuer die Test-Assertions dupliziert statt exportiert).
const _fallbackColor = Color(0xFFEA580C);

void main() {
  group('colorForSungPoint', () {
    test('Punkt exakt auf start_t einer Notenspanne bekommt deren Farbe', () {
      const ranges = [
        NoteColorRange(startT: 1.0, endT: 2.0, classification: 'green'),
      ];
      expect(colorForSungPoint(1.0, ranges), Colors.green.shade300);
    });

    test('Punkt exakt auf end_t gehoert bereits zur naechsten Notenspanne', () {
      const ranges = [
        NoteColorRange(startT: 0.0, endT: 1.0, classification: 'green'),
        NoteColorRange(startT: 1.0, endT: 2.0, classification: 'yellow'),
      ];
      expect(colorForSungPoint(1.0, ranges), Colors.amber.shade300);
    });

    test('Punkt vor der ersten Notenspanne bekommt die Fallback-Farbe', () {
      const ranges = [
        NoteColorRange(startT: 1.0, endT: 2.0, classification: 'red'),
      ];
      expect(colorForSungPoint(0.5, ranges), _fallbackColor);
    });

    test(
        'Punkt kurz nach dem Ende der letzten Note (innerhalb der '
        '0.3s-Toleranz) bekommt noch deren Farbe', () {
      const ranges = [
        NoteColorRange(startT: 5.0, endT: 6.0, classification: 'red'),
      ];
      expect(colorForSungPoint(6.2, ranges), Colors.red.shade300);
    });

    test(
        'Punkt deutlich nach dem Ende der letzten Note (ausserhalb der '
        'Toleranz) bekommt die Fallback-Farbe', () {
      const ranges = [
        NoteColorRange(startT: 5.0, endT: 6.0, classification: 'red'),
      ];
      expect(colorForSungPoint(6.5, ranges), _fallbackColor);
    });

    test('Leere Notenliste ergibt die Fallback-Farbe', () {
      expect(colorForSungPoint(1.0, const []), _fallbackColor);
    });

    test('null als Notenliste ergibt die Fallback-Farbe (Zustand vor der Bewertung)', () {
      expect(colorForSungPoint(1.0, null), _fallbackColor);
    });

    test('Unbekannter Klassifizierungs-String faellt auf die Fallback-Farbe zurueck', () {
      const ranges = [
        NoteColorRange(startT: 1.0, endT: 2.0, classification: 'purple'),
      ];
      expect(colorForSungPoint(1.5, ranges), _fallbackColor);
    });
  });
}

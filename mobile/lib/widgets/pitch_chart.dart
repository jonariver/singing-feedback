import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/sung_point.dart';
import '../models/target_point.dart';

const _noteNames = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'B', 'H'];
const _targetColor = Color(0xFF00C2CB);
const _sungColor = Color(0xFFEA580C);

// Spiegelt backend/config.py::LAST_NOTE_TAIL_TOLERANCE_SECONDS, damit die
// Chart-Faerbung der letzten Note exakt mit der Backend-Zuordnung in
// backend/scoring/notes.py::attribute_sung_frames uebereinstimmt.
const double _lastNoteTailToleranceSeconds = 0.3;

double _hzToMidiNote(double hz) => 69 + 12 * (math.log(hz / 440) / math.ln2);

String _midiNoteName(int n) {
  final name = _noteNames[((n % 12) + 12) % 12];
  final octave = (n / 12).floor() - 1;
  return '$name$octave';
}

/// Zeitspanne einer bewerteten Note mit ihrer Cent-Klassifizierung, gebaut aus
/// ScoreNote (siehe models/score_result.dart) fuer die Kurvenfaerbung in
/// PitchChart. Bewusst kein Modell in models/, da keine JSON-(De-)Serialisierung
/// noetig ist - reine Darstellungs-Hilfsklasse.
class NoteColorRange {
  final double startT;
  final double endT;
  final String classification; // 'green' | 'yellow' | 'red'

  const NoteColorRange({required this.startT, required this.endT, required this.classification});
}

Color _classificationColor(String classification) => switch (classification) {
      'green' => Colors.green.shade300,
      'yellow' => Colors.amber.shade300,
      'red' => Colors.red.shade300,
      _ => _sungColor,
    };

/// Ermittelt die Kurvenfarbe fuer einen Ist-Kurven-Punkt anhand seiner Zeit t
/// (bereits aligned_t ?? t) und der Notenspannen aus der Bewertung. Reine, von
/// Canvas/CustomPainter entkoppelte Funktion, direkt unit-testbar (siehe
/// pitch_chart_test.dart). Liegt t in keiner Spanne (davor, danach ausserhalb
/// der Toleranz, oder keine/leere Liste), gilt die Fallback-Farbe _sungColor.
Color colorForSungPoint(double t, List<NoteColorRange>? ranges) {
  if (ranges == null) return _sungColor;
  for (var i = 0; i < ranges.length; i++) {
    final range = ranges[i];
    final isLast = i == ranges.length - 1;
    final effectiveEndT = isLast ? range.endT + _lastNoteTailToleranceSeconds : range.endT;
    if (t >= range.startT && t < effectiveEndT) {
      return _classificationColor(range.classification);
    }
  }
  return _sungColor;
}

class _CurvePoint {
  final double t;
  final double? hz;
  const _CurvePoint(this.t, this.hz);
}

/// Port von drawChart()/drawCurve() aus frontend/app.js: Notennamen-Y-Achse mit
/// Oktavlinien, Zeit-X-Achse, Ziel- (teal) und Ist-Kurve ueberlagert, mit Luecken
/// bei fehlenden bzw. unvoiced Punkten. Die Ist-Kurve ist segment-farbig (gruen/gelb/rot)
/// nach Cent-Klassifizierung, wenn noteColorRanges vorhanden (Phase 5); sonst fallback
/// auf orange. Die Zielkurvenfarbe weicht bewusst von frontend/app.js ab (dort weiterhin blau),
/// da nur der Mobile-Client im Zuge des Dark-Teal-Redesigns umgefaerbt wurde.
class PitchChart extends StatelessWidget {
  final List<TargetPoint> targetCurve;
  final List<SungPoint> sungCurve;
  final List<NoteColorRange>? noteColorRanges;

  const PitchChart({
    super.key,
    required this.targetCurve,
    required this.sungCurve,
    this.noteColorRanges,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return CustomPaint(
          size: Size(constraints.maxWidth, constraints.maxHeight),
          painter: _PitchChartPainter(
            targetCurve: targetCurve,
            sungCurve: sungCurve,
            noteColorRanges: noteColorRanges,
          ),
        );
      },
    );
  }
}

class _PitchChartPainter extends CustomPainter {
  final List<TargetPoint> targetCurve;
  final List<SungPoint> sungCurve;
  final List<NoteColorRange>? noteColorRanges;

  _PitchChartPainter({
    required this.targetCurve,
    required this.sungCurve,
    this.noteColorRanges,
  });

  static const double _padLeft = 46;
  static const double _padRight = 12;
  static const double _padTop = 12;
  static const double _padBottom = 28;
  static const _gridColor = Color(0x339CA3AF);
  static const _labelColor = Color(0xFF9CA3AF);

  static double _sungDisplayT(SungPoint p) => p.alignedT ?? p.t;

  @override
  void paint(Canvas canvas, Size size) {
    final targetNotes =
        targetCurve.where((p) => p.hz != null).map((p) => _hzToMidiNote(p.hz!)).toList();
    final sungNotes = sungCurve
        .where((p) => p.voiced && p.hz != null)
        .map((p) => _hzToMidiNote(p.hz!))
        .toList();
    final allNotes = [...targetNotes, ...sungNotes];

    if (allNotes.isEmpty) {
      _paintText(
        canvas,
        'Noch keine Daten. Bitte MIDI-Spur und Aufnahme hochladen.',
        Offset(20, size.height / 2),
        color: _labelColor,
        fontSize: 14,
      );
      return;
    }

    final maxTime = [
      targetCurve.isNotEmpty ? targetCurve.last.t : 0.0,
      sungCurve.isNotEmpty ? _sungDisplayT(sungCurve.last) : 0.0,
      1.0,
    ].reduce(math.max);
    final minNote = allNotes.reduce(math.min).floor() - 2;
    final maxNote = allNotes.reduce(math.max).ceil() + 2;

    final plotWidth = size.width - _padLeft - _padRight;
    final plotHeight = size.height - _padTop - _padBottom;

    double xForT(double t) => _padLeft + (t / maxTime) * plotWidth;
    double yForNote(double n) =>
        _padTop + (1 - (n - minNote) / (maxNote - minNote)) * plotHeight;

    final gridPaint = Paint()
      ..color = _gridColor
      ..strokeWidth = 1;

    final firstGridNote = (minNote / 12).ceil() * 12;
    for (int n = firstGridNote; n <= maxNote; n += 12) {
      final y = yForNote(n.toDouble());
      canvas.drawLine(Offset(_padLeft, y), Offset(size.width - _padRight, y), gridPaint);
      _paintText(canvas, _midiNoteName(n), Offset(4, y - 6), color: _labelColor, fontSize: 11);
    }

    final secondStep = maxTime > 30 ? 5 : 2;
    for (double s = 0; s <= maxTime; s += secondStep) {
      final x = xForT(s);
      _paintText(
        canvas,
        '${s.toInt()}s',
        Offset(x - 8, size.height - 18),
        color: _labelColor,
        fontSize: 11,
      );
    }

    _drawCurve(
      canvas,
      targetCurve.map((p) => _CurvePoint(p.t, p.hz)).toList(),
      xForT,
      yForNote,
      _targetColor,
    );
    _drawCurve(
      canvas,
      sungCurve.map((p) => _CurvePoint(_sungDisplayT(p), p.voiced ? p.hz : null)).toList(),
      xForT,
      yForNote,
      _sungColor,
      noteColorRanges: noteColorRanges,
    );
  }

  void _paintText(
    Canvas canvas,
    String text,
    Offset offset, {
    required Color color,
    required double fontSize,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: TextStyle(color: color, fontSize: fontSize)),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, offset);
  }

  void _drawCurve(
    Canvas canvas,
    List<_CurvePoint> points,
    double Function(double) xForT,
    double Function(double) yForNote,
    Color defaultColor, {
    List<NoteColorRange>? noteColorRanges,
  }) {
    Path? currentPath;
    Color? currentColor;
    Offset? lastOffset;

    void flush() {
      if (currentPath != null && currentColor != null) {
        canvas.drawPath(
          currentPath!,
          Paint()
            ..color = currentColor!
            ..strokeWidth = 2
            ..style = PaintingStyle.stroke,
        );
      }
      currentPath = null;
      currentColor = null;
    }

    for (final p in points) {
      if (p.hz == null) {
        flush();
        lastOffset = null;
        continue;
      }
      final offset = Offset(xForT(p.t), yForNote(_hzToMidiNote(p.hz!)));
      final color = noteColorRanges == null ? defaultColor : colorForSungPoint(p.t, noteColorRanges);

      if (currentPath == null) {
        currentPath = Path()..moveTo(offset.dx, offset.dy);
        currentColor = color;
      } else if (color != currentColor) {
        flush();
        currentPath = Path()
          ..moveTo(lastOffset!.dx, lastOffset.dy)
          ..lineTo(offset.dx, offset.dy);
        currentColor = color;
      } else {
        currentPath!.lineTo(offset.dx, offset.dy);
      }
      lastOffset = offset;
    }
    flush();
  }

  @override
  bool shouldRepaint(covariant _PitchChartPainter oldDelegate) {
    return oldDelegate.targetCurve != targetCurve ||
        oldDelegate.sungCurve != sungCurve ||
        oldDelegate.noteColorRanges != noteColorRanges;
  }
}

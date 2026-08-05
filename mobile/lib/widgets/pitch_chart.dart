import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/sung_point.dart';
import '../models/target_point.dart';

const _noteNames = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];

double _hzToMidiNote(double hz) => 69 + 12 * (math.log(hz / 440) / math.ln2);

String _midiNoteName(int n) {
  final name = _noteNames[((n % 12) + 12) % 12];
  final octave = (n / 12).floor() - 1;
  return '$name$octave';
}

class _CurvePoint {
  final double t;
  final double? hz;
  const _CurvePoint(this.t, this.hz);
}

/// 1:1-Port von drawChart()/drawCurve() aus frontend/app.js: Notennamen-Y-Achse mit
/// Oktavlinien, Zeit-X-Achse, Ziel- (blau) und Ist-Kurve (orange) ueberlagert, mit
/// Luecken bei fehlenden bzw. unvoiced Punkten.
class PitchChart extends StatelessWidget {
  final List<TargetPoint> targetCurve;
  final List<SungPoint> sungCurve;

  const PitchChart({super.key, required this.targetCurve, required this.sungCurve});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return CustomPaint(
          size: Size(constraints.maxWidth, constraints.maxHeight),
          painter: _PitchChartPainter(targetCurve: targetCurve, sungCurve: sungCurve),
        );
      },
    );
  }
}

class _PitchChartPainter extends CustomPainter {
  final List<TargetPoint> targetCurve;
  final List<SungPoint> sungCurve;

  _PitchChartPainter({required this.targetCurve, required this.sungCurve});

  static const double _padLeft = 46;
  static const double _padRight = 12;
  static const double _padTop = 12;
  static const double _padBottom = 28;
  static const _targetColor = Color(0xFF2563EB);
  static const _sungColor = Color(0xFFEA580C);
  static const _gridColor = Color(0x339CA3AF);
  static const _labelColor = Color(0xFF9CA3AF);

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
      sungCurve.isNotEmpty ? sungCurve.last.t : 0.0,
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
      sungCurve.map((p) => _CurvePoint(p.t, p.voiced ? p.hz : null)).toList(),
      xForT,
      yForNote,
      _sungColor,
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
    Color color,
  ) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    final path = Path();
    bool drawing = false;
    for (final p in points) {
      if (p.hz == null) {
        drawing = false;
        continue;
      }
      final x = xForT(p.t);
      final y = yForNote(_hzToMidiNote(p.hz!));
      if (!drawing) {
        path.moveTo(x, y);
        drawing = true;
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _PitchChartPainter oldDelegate) {
    return oldDelegate.targetCurve != targetCurve || oldDelegate.sungCurve != sungCurve;
  }
}

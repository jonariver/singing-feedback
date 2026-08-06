# Grün/Gelb/Rot-Einfärbung im Pitch-Chart Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Die gesungene Kurve im `PitchChart` wird segmentweise nach der Cent-Klassifizierung (grün/gelb/rot) der zugehörigen Note eingefärbt, statt durchgehend orange zu sein.

**Architecture:** Rein Mobile-seitig, kein Backend-Change. `home_screen.dart` baut aus `session.scoreResult?.notes` eine Liste leichter `NoteColorRange`-Objekte (Zeitspanne + Klassifizierung) und übergibt sie an `PitchChart`. Eine neue, pure Funktion `colorForSungPoint(t, ranges)` in `pitch_chart.dart` ordnet jedem Ist-Kurven-Punkt (per `aligned_t ?? t`) die passende Farbe zu; `_PitchChartPainter._drawCurve()` nutzt sie, um die Ist-Kurve in mehreren farbigen Pfad-Segmenten statt einem einzigen zu zeichnen.

**Tech Stack:** Flutter/Dart, `flutter_test` für Unit-Tests der reinen Farblogik.

## Global Constraints

- Nur die **Ist-Kurve** (gesungene Kurve) wird eingefärbt, die Ziel-Kurve bleibt unverändert teal.
- Farblogik basiert **ausschließlich** auf `centsClassification` der zugeordneten Note — Timing/Stabilität/Phrasenende-Drift fließen nicht in die Kurvenfarbe ein.
- Farbwerte identisch zu `ScoreSummaryView._classificationColor`: `green` → `Colors.green.shade300`, `yellow` → `Colors.amber.shade300`, `red` → `Colors.red.shade300`.
- Punkte außerhalb jeder Notenspanne behalten die bisherige Fallback-Farbe Orange (`Color(0xFFEA580C)`, bisher `_sungColor`).
- Die letzte Notenspanne bekommt beim Lookup dieselbe `0.3`-Sekunden-Toleranz wie `backend/config.py::LAST_NOTE_TAIL_TOLERANCE_SECONDS` (Backend-seitig für `attribute_sung_frames` verwendet), damit die Chart-Färbung mit der Backend-Zuordnung übereinstimmt.
- Verfehlte Noten und die Ist-Kurve selbst bekommen keine visuelle Sonderbehandlung (bleiben eine Lücke wie heute schon bei unvoiced Punkten).
- Fehlt eine Bewertung (`session.scoreResult == null`), bleibt die Ist-Kurve komplett wie im heutigen Zustand einfarbig orange — kein Verhaltensbruch.

---

### Task 1: Farblogik + Chart-Rendering + HomeScreen-Wiring

**Files:**
- Modify: `mobile/lib/widgets/pitch_chart.dart`
- Modify: `mobile/lib/screens/home_screen.dart:130-137`
- Test: `mobile/test/pitch_chart_test.dart` (neu)

**Interfaces:**
- Produces (in `pitch_chart.dart`):
  - `class NoteColorRange { final double startT; final double endT; final String classification; const NoteColorRange({required this.startT, required this.endT, required this.classification}); }`
  - `Color colorForSungPoint(double t, List<NoteColorRange>? ranges)` — top-level Funktion, pure, keine Canvas-Abhängigkeit.
  - `PitchChart` bekommt neuen optionalen Konstruktor-Parameter `final List<NoteColorRange>? noteColorRanges;`.
- Consumes (aus bestehendem Code): `ScoreResult`/`ScoreNote` (`mobile/lib/models/score_result.dart`) mit Feldern `startT`, `endT`, `centsClassification` (bereits vorhanden, Phase 4); `SessionState.scoreResult` (bereits vorhanden).

Aktueller Stand von `mobile/lib/widgets/pitch_chart.dart` (Referenz für die folgenden Diffs — Zeilenangaben beziehen sich auf diesen Stand):

```dart
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
  static const _targetColor = Color(0xFF00C2CB);
  static const _sungColor = Color(0xFFEA580C);
  static const _gridColor = Color(0x339CA3AF);
  static const _labelColor = Color(0xFF9CA3AF);

  static double _sungDisplayT(SungPoint p) => p.alignedT ?? p.t;

  @override
  void paint(Canvas canvas, Size size) {
    // ... (unveraendert bis zu den beiden _drawCurve-Aufrufen)

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
    );
  }

  // ... _paintText unveraendert ...

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
```

- [ ] **Step 1: Failing-Test-Datei schreiben**

Erstelle `mobile/test/pitch_chart_test.dart`:

```dart
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
```

- [ ] **Step 2: Test ausfuehren, Fehlschlag bestaetigen**

Run: `cd mobile && flutter test test/pitch_chart_test.dart`
Expected: FAIL — `NoteColorRange`/`colorForSungPoint` sind nicht definiert (Compile-Fehler).

- [ ] **Step 3: `NoteColorRange` + `colorForSungPoint` implementieren, Farbkonstanten hochziehen**

In `mobile/lib/widgets/pitch_chart.dart`: die beiden Farbkonstanten `_targetColor`/`_sungColor` aus `_PitchChartPainter` auf Top-Level ziehen (damit sowohl die Klasse als auch die neue freie Funktion sie nutzen koennen), und direkt darunter `NoteColorRange`, die Toleranz-Konstante und `colorForSungPoint` ergaenzen. Ersetze den Block ab `const _noteNames = ...` bis vor `class _CurvePoint` durch:

```dart
const _noteNames = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
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
```

Danach in `_PitchChartPainter` die beiden Zeilen `static const _targetColor = Color(0xFF00C2CB);` und `static const _sungColor = Color(0xFFEA580C);` loeschen (jetzt Top-Level-Duplikate) — die restlichen `static const`-Felder (`_padLeft` etc.) bleiben unveraendert in der Klasse, da sie nirgends außerhalb gebraucht werden.

- [ ] **Step 4: Test ausfuehren, Erfolg bestaetigen**

Run: `cd mobile && flutter test test/pitch_chart_test.dart`
Expected: PASS, alle 8 Tests gruen.

- [ ] **Step 5: `_drawCurve` fuer mehrfarbige Segmente umbauen**

Ersetze die bestehende `_drawCurve`-Methode in `_PitchChartPainter` durch:

```dart
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
          ..moveTo(lastOffset!.dx, lastOffset!.dy)
          ..lineTo(offset.dx, offset.dy);
        currentColor = color;
      } else {
        currentPath!.lineTo(offset.dx, offset.dy);
      }
      lastOffset = offset;
    }
    flush();
  }
```

Das erhaelt das bisherige Luecken-Verhalten (Pfadabbruch bei `p.hz == null`) und faengt bei jedem Farbwechsel einen neuen Pfad an, der beim vorherigen Punkt beginnt (`moveTo(lastOffset...)`) und den aktuellen Punkt anhaengt (`lineTo(...)`) — dadurch bleibt die Linie an Farbwechseln optisch durchgehend statt eine Luecke zu zeigen.

- [ ] **Step 6: `PitchChart`/`_PitchChartPainter` um `noteColorRanges` erweitern und verdrahten**

In `PitchChart`:

```dart
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
```

In `_PitchChartPainter`: Feld + Konstruktor-Parameter ergaenzen:

```dart
class _PitchChartPainter extends CustomPainter {
  final List<TargetPoint> targetCurve;
  final List<SungPoint> sungCurve;
  final List<NoteColorRange>? noteColorRanges;

  _PitchChartPainter({
    required this.targetCurve,
    required this.sungCurve,
    this.noteColorRanges,
  });
```

Den zweiten `_drawCurve`-Aufruf (Ist-Kurve) in `paint()` um den neuen benannten Parameter erweitern:

```dart
    _drawCurve(
      canvas,
      sungCurve.map((p) => _CurvePoint(_sungDisplayT(p), p.voiced ? p.hz : null)).toList(),
      xForT,
      yForNote,
      _sungColor,
      noteColorRanges: noteColorRanges,
    );
```

(Der erste Aufruf fuer `targetCurve` bleibt unveraendert — kein `noteColorRanges`-Argument, damit die Zielkurve wie bisher durchgehend teal bleibt.)

`shouldRepaint` um den neuen Vergleich erweitern:

```dart
  @override
  bool shouldRepaint(covariant _PitchChartPainter oldDelegate) {
    return oldDelegate.targetCurve != targetCurve ||
        oldDelegate.sungCurve != sungCurve ||
        oldDelegate.noteColorRanges != noteColorRanges;
  }
```

- [ ] **Step 7: In `home_screen.dart` verdrahten**

In `mobile/lib/screens/home_screen.dart:130-137` (Abschnitt "3. Tonhöhen-Vergleich"), ersetze:

```dart
              child: PitchChart(
                targetCurve: session.displayedTargetCurve,
                sungCurve: session.displayedSungCurve,
              ),
```

durch:

```dart
              child: PitchChart(
                targetCurve: session.displayedTargetCurve,
                sungCurve: session.displayedSungCurve,
                noteColorRanges: session.scoreResult?.notes
                    .map((n) => NoteColorRange(
                          startT: n.startT,
                          endT: n.endT,
                          classification: n.centsClassification,
                        ))
                    .toList(),
              ),
```

Kein neuer Import noetig — `NoteColorRange` ist Teil von `pitch_chart.dart`, das `home_screen.dart` bereits importiert (`import '../widgets/pitch_chart.dart';`).

- [ ] **Step 8: Vollen Test-Suite-Lauf und Analyse verifizieren**

Run: `cd mobile && flutter test -j 1`
Expected: alle Tests gruen (bestehende Suite + die 8 neuen `pitch_chart_test.dart`-Tests).

Run: `cd mobile && flutter analyze`
Expected: keine Fehler/Warnungen.

- [ ] **Step 9: Commit**

```bash
git add mobile/lib/widgets/pitch_chart.dart mobile/lib/screens/home_screen.dart mobile/test/pitch_chart_test.dart
git commit -m "feat: color the sung pitch curve by note cent-classification (green/yellow/red)"
```

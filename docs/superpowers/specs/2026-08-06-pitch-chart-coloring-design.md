# Grün/Gelb/Rot-Einfärbung im Pitch-Chart (Phase 5)

Status: Design abgestimmt am 2026-08-06, bereit für Implementierungsplan.

## Kontext

Phase 4 "Kernpaket" (`backend/scoring/`) ist fertig und liefert über `POST
/api/score` pro Note bereits eine Cent-Klassifizierung
(`cents_deviation.classification`: `green`/`yellow`/`red`) sowie deren
Zeitspanne (`start_t`, `end_t`). Der Mobile-Client zeigt das bisher nur als
Text-Zusammenfassung (`ScoreSummaryView`) an — der Kommentar in
`mobile/lib/widgets/score_summary_view.dart` hält explizit fest, dass die
Kurvenfärbung im Chart "bewusst" für eine spätere, separate Phase
zurückgestellt wurde. Genau das ist Phase 5.

Da Sung-Frames bereits über `aligned_t` (aus der DTW-Ausrichtung, Phase 3)
in derselben Zeitbasis wie `note.start_t`/`end_t` liegen — `backend/
scoring/notes.py::attribute_sung_frames` nutzt exakt diesen Abgleich, um
Frames einer Note zuzuordnen —, kann der Client dieselbe Zuordnung
client-seitig nachvollziehen, ohne dass das Backend zusätzliche Daten
liefern muss. **Dieses Feature ist rein Mobile-seitig, kein Backend-Change
nötig.**

## Architektur / Datenfluss

`PitchChart` (`mobile/lib/widgets/pitch_chart.dart`) bekommt einen neuen,
optionalen Parameter für Notenzeitspannen mit Klassifizierung. `home_screen
.dart` baut diese Liste aus `session.scoreResult?.notes` (jede `ScoreNote`
hat bereits `startT`, `endT`, `centsClassification`) und übergibt sie beim
Bau des `PitchChart`-Widgets in Abschnitt "3. Tonhöhen-Vergleich".
`SessionState` und die Backend-API bleiben unverändert.

Ist noch keine Bewertung vorhanden (`session.scoreResult == null`, z.B.
bevor die Aufnahme bewertet wurde), bleibt der Parameter leer/null und die
Ist-Kurve wird exakt wie heute einfarbig orange gezeichnet — reine additive
Erweiterung, kein Verhaltensbruch für den bisherigen Zustand.

**Neuer Typ** (co-located in `pitch_chart.dart`, da reine Darstellungs-
Hilfsklasse ohne JSON-(De-)Serialisierung, im Gegensatz zu den API-Modellen
in `mobile/lib/models/`):

```dart
class NoteColorRange {
  final double startT;
  final double endT;
  final String classification; // 'green' | 'yellow' | 'red'
  const NoteColorRange({required this.startT, required this.endT, required this.classification});
}
```

`home_screen.dart` baut die Liste so:

```dart
noteColorRanges: session.scoreResult?.notes
    .map((n) => NoteColorRange(startT: n.startT, endT: n.endT, classification: n.centsClassification))
    .toList(),
```

## Rendering-Logik

`_PitchChartPainter._drawCurve()` zeichnet die Ist-Kurve schon heute
punktweise und bricht den Pfad bei Lücken (unvoiced/fehlender Punkt) neu
auf. Für die Ist-Kurve wird das erweitert: pro Punkt wird per `aligned_t ??
t` (bereits vorhandene `_sungDisplayT`-Hilfsfunktion) in den übergebenen
`NoteColorRange`s nachgeschlagen, welcher Note (und damit Farbe) der Punkt
zugeordnet ist. Ändert sich die Farbe zwischen zwei aufeinanderfolgenden
Punkten, wird — genau wie bei den bestehenden Lücken — ein neuer
Pfad-Abschnitt begonnen und mit der neuen Farbe gezeichnet, statt einen
einzelnen mehrfarbigen `Path` zu versuchen.

**Farben**, identisch zu `ScoreSummaryView._classificationColor`, damit
Chart und Text-Zusammenfassung optisch übereinstimmen:
- `green` → `Colors.green.shade300`
- `yellow` → `Colors.amber.shade300`
- `red` → `Colors.red.shade300`
- Kein Treffer in `noteColorRanges` (Punkt liegt außerhalb jeder
  Notenspanne — Pausen, Lücke vor der ersten/nach der letzten Note) → das
  bisherige Orange (`_sungColor`, `0xFFEA580C`), unverändert.

Die Farblogik ist bewusst **nur** die Cent-Klassifizierung — Timing-,
Stabilitäts- und Phrasenende-Drift-Flags bleiben reine Text-Hinweise in
`ScoreSummaryView` und fließen nicht in die Kurvenfarbe ein. Eine Note gibt
also immer genau eine, eindeutige Farbe vor.

**Letzte Note / Toleranz:** `attribute_sung_frames` im Backend erweitert
bei der letzten Note die Endzeit um `LAST_NOTE_TAIL_TOLERANCE_SECONDS`
(aktuell `0.3` in `backend/config.py`), damit nachklingende Frames noch der
letzten Note zugerechnet werden. Damit die Chart-Färbung exakt mit der
Backend-Zuordnung übereinstimmt (statt am Phrasenende leicht davon
abzuweichen), übernimmt der Lookup dieselbe Toleranz für die letzte
Zeitspanne in `noteColorRanges` — als eigene, client-seitige Konstante mit
demselben Wert `0.3`, dokumentiert mit einem Verweis auf
`backend/config.py::LAST_NOTE_TAIL_TOLERANCE_SECONDS`.

**Verfehlte Noten und nicht zugeordnete Frames:** keine Sonderdarstellung.
Verfehlte Noten (kein zugeordneter Ist-Frame vorhanden) bleiben eine Lücke
in der Ist-Kurve, wie es unvoiced/fehlende Punkte heute schon sind — die
Text-Zusammenfassung zeigt "verfehlt" bereits an. Frames außerhalb jeder
Notenspanne bleiben Orange.

Die Zielkurve (`targetCurve`, teal) bleibt vollständig unverändert — nur
die Ist-Kurve wird eingefärbt.

## Testing

Die Zeit→Farbe-Zuordnung wird als eigenständige, von `CustomPainter`/
`Canvas` entkoppelte Funktion gebaut (z.B. `Color _colorForSungPoint(double
t, List<NoteColorRange> ranges)`), damit sie direkt unit-testbar ist, ohne
ein Widget zu pumpen oder einen Canvas zu faken. `pitch_chart.dart` hat
aktuell keine Tests; dies ist die Gelegenheit, wenigstens die neue
Kernlogik testbar zu machen, ohne den bestehenden, ungetesteten
Rendering-Code (`CustomPainter.paint()`) anzufassen oder umzustrukturieren.

Neue Testdatei `mobile/test/pitch_chart_test.dart` (bisher nicht
vorhanden), deckt die Lookup-Funktion ab:
- Punkt exakt auf `start_t` einer Notenspanne → deren Farbe.
- Punkt exakt auf `end_t` (exklusiv, außer letzte Note mit Toleranz) →
  nächste Notenspanne bzw. Fallback-Farbe.
- Punkt vor der ersten Notenspanne → Fallback-Farbe (Orange).
- Punkt nach der letzten Notenspanne, aber innerhalb der
  0.3s-Toleranz → Farbe der letzten Note.
- Punkt deutlich nach der letzten Notenspanne (außerhalb der Toleranz) →
  Fallback-Farbe.
- Leere `noteColorRanges`-Liste bzw. `null` → Fallback-Farbe für jeden
  Punkt (deckt den "noch keine Bewertung"-Zustand ab).
- Unbekannter `classification`-String (Robustheit) → Fallback-Farbe statt
  Absturz.

## Out of Scope (bewusst nicht Teil dieses Designs)

- Keine Einfärbung der Zielkurve, keine Notengrenzen-Markierung.
- Keine Vermischung von Timing-/Stabilitäts-/Drift-Flags in die
  Kurvenfarbe — nur Cent-Klassifizierung.
- Keine visuelle Sonderdarstellung für verfehlte Noten im Chart.
- Kein Backend-Change — alle benötigten Daten liefert `POST /api/score`
  bereits.

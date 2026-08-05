# Dark/Teal-Redesign aus Figma-Referenz Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Der Flutter-Client (`mobile/`) übernimmt den visuellen Stil einer Figma-Referenz
(Musium Music-App-UI, Community-File) — dunkler Hintergrund, Teal-Akzente, abgerundete
Pill-/Kreis-Buttons, geometrische Sans-Serif-Schrift — auf allen drei bestehenden
Screen-Abschnitten, ohne deren Funktionalität zu ändern.

**Architecture:** Ein globales `ThemeData` in `main.dart` (Farbschema, Typografie, Button-Form)
deckt den Großteil ab, da alle Widgets bereits `Theme.of(context)`/Standard-Material-Widgets
nutzen. Vier Dateien haben zusätzlich fest verdrahtete, auf helles Theme abgestimmte Farben,
die einzeln auf den dunklen Hintergrund angepasst werden.

**Tech Stack:** Flutter/Dart (`mobile/`), neues Package `google_fonts` (Schriftart "Jost" als
Century-Gothic-Ersatz), Material 3.

## Global Constraints

- Keine neue Navigationsstruktur oder Bibliotheks-/Playlist-Funktion aus dem Figma-File —
  nur Farben/Typografie/Formen auf die bestehenden drei Abschnitte anwenden.
- `frontend/app.js` (Web-Frontend) bleibt unverändert.
- Keine neue Test-Infrastruktur (Golden-Image-Tests) — Verifikation ist visuell per
  Emulator-Screenshot, nicht automatisiert.
- Bestehende automatisierte Suite (aktuell 8/8) muss unverändert grün bleiben, da dieser Plan
  ihr Verhalten nicht ändert (nur Text-Assertions, keine Farb-Assertions vorhanden).

---

## Datei-Übersicht

- **Modify:** `mobile/pubspec.yaml` — neue Abhängigkeit `google_fonts`.
- **Modify:** `mobile/lib/main.dart` — komplettes dunkles `ThemeData` (Farben, Schrift, Formen).
- **Modify:** `mobile/lib/widgets/pitch_chart.dart` — Zielkurven-Farbe auf Teal.
- **Modify:** `mobile/lib/widgets/track_candidate_card.dart` — Auswahl-Hintergrund und
  Warnungstext auf dunkles Theme angepasst.
- **Modify:** `mobile/lib/widgets/status_banner.dart` — Status-Farben aufgehellt.
- **Modify:** `mobile/lib/widgets/recording_control.dart` — Play/Pause-Button als gefüllter
  Kreis-Button (Figma-Look), Fehlertext-Farbe konsistent mit `status_banner.dart` aufgehellt
  (beim Schreiben dieses Plans entdeckt: derselbe zu-dunkle-Rot-Ton wie in `status_banner.dart`,
  war im Design noch nicht explizit benannt, folgt aber demselben bereits abgestimmten Prinzip).

---

### Task 1: Theme-Basis (`main.dart` + `pubspec.yaml`)

**Files:**
- Modify: `mobile/pubspec.yaml`
- Modify: `mobile/lib/main.dart`

**Interfaces:**
- Produces: `ThemeData` mit `colorScheme.primary = Color(0xFF00C2CB)`,
  `colorScheme.secondary = Color(0xFF39C0D4)`, `colorScheme.surface = Color(0xFF121111)`,
  `colorScheme.onSurfaceVariant = Color(0xFF8A9A9D)`, `brightness = Brightness.dark`,
  `StadiumBorder`-Form für `ElevatedButton`/`SegmentedButton`. Nachfolgende Tasks lesen
  `Theme.of(context).colorScheme.primary` für die Teal-Akzentfarbe.

- [ ] **Step 1: `google_fonts` zur pubspec.yaml hinzufügen**

Öffne `mobile/pubspec.yaml`. Füge unter `dependencies:` (nach `audioplayers: ^6.0.0`, vor
`http: ^1.2.0`) diese Zeile ein:

```yaml
  google_fonts: ^6.2.1
```

Run: `cd mobile && flutter pub get`
Expected: `Got dependencies!` ohne Fehler, `google_fonts` erscheint in der Ausgabe.

- [ ] **Step 2: `main.dart` auf dunkles Theme umstellen**

Ersetze den kompletten Inhalt von `mobile/lib/main.dart` durch:

```dart
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'api/api_client.dart';
import 'api/audio_api.dart';
import 'api/midi_api.dart';
import 'screens/home_screen.dart';
import 'state/session_state.dart';

void main() {
  runApp(const SingingFeedbackApp());
}

class SingingFeedbackApp extends StatelessWidget {
  const SingingFeedbackApp({super.key});

  @override
  Widget build(BuildContext context) {
    final apiClient = ApiClient();
    return ChangeNotifierProvider(
      create: (_) => SessionState(
        midiApi: MidiApi(apiClient),
        audioApi: AudioApi(apiClient),
      ),
      child: MaterialApp(
        title: 'Singing Feedback',
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF00C2CB),
            brightness: Brightness.dark,
          ).copyWith(
            primary: const Color(0xFF00C2CB),
            secondary: const Color(0xFF39C0D4),
            surface: const Color(0xFF121111),
            onSurfaceVariant: const Color(0xFF8A9A9D),
          ),
          textTheme: GoogleFonts.jostTextTheme(ThemeData(brightness: Brightness.dark).textTheme)
              .apply(fontWeightDelta: 1),
          elevatedButtonTheme: ElevatedButtonThemeData(
            style: ElevatedButton.styleFrom(shape: const StadiumBorder()),
          ),
          segmentedButtonTheme: SegmentedButtonThemeData(
            style: SegmentedButton.styleFrom(shape: const StadiumBorder()),
          ),
        ),
        home: const HomeScreen(),
      ),
    );
  }
}
```

- [ ] **Step 3: Statische Analyse**

Run: `cd mobile && flutter analyze`
Expected: "No issues found!"

- [ ] **Step 4: Bestehende Test-Suite gegenprüfen**

Run: `cd mobile && flutter test test/widget_test.dart` und separat
`flutter test test/session_state_test.dart` (einzeln laufen lassen wegen des bekannten
Flutter-Test-Runner-Anzeigefehlers bei mehreren Dateien gleichzeitig — siehe Global
Constraints früherer Pläne in diesem Projekt)
Expected: weiterhin 8/8 bestehend (2 + 6), unverändert gegenüber vor diesem Task — reine
Theme-Änderungen ändern kein von den Tests geprüftes Verhalten (nur Text-Assertions).

- [ ] **Step 5: Commit**

```bash
git add mobile/pubspec.yaml mobile/pubspec.lock mobile/lib/main.dart
git commit -m "feat: apply dark/teal theme base from Figma reference"
```

---

### Task 2: Einzel-Widget-Farbanpassungen

**Files:**
- Modify: `mobile/lib/widgets/pitch_chart.dart`
- Modify: `mobile/lib/widgets/track_candidate_card.dart`
- Modify: `mobile/lib/widgets/status_banner.dart`
- Modify: `mobile/lib/widgets/recording_control.dart`

**Interfaces:**
- Consumes: `Theme.of(context).colorScheme.primary` (aus Task 1, jetzt `Color(0xFF00C2CB)`).
- Produces: keine neuen öffentlichen Symbole — reine Farbwert-Änderungen innerhalb
  bestehender Methoden/Konstanten.

- [ ] **Step 1: `pitch_chart.dart` — Zielkurve auf Teal**

Öffne `mobile/lib/widgets/pitch_chart.dart`. Ersetze Zeile 56:

```dart
  static const _targetColor = Color(0xFF2563EB);
```

durch:

```dart
  static const _targetColor = Color(0xFF00C2CB);
```

(`_sungColor`, `_gridColor`, `_labelColor` bleiben unverändert.)

- [ ] **Step 2: `track_candidate_card.dart` — Auswahl-Hintergrund und Warnungstext**

Öffne `mobile/lib/widgets/track_candidate_card.dart`. Ersetze:

```dart
    return Card(
      color: selected ? Colors.blue.shade50 : null,
```

durch:

```dart
    return Card(
      color: selected ? Theme.of(context).colorScheme.primary.withOpacity(0.15) : null,
```

Und ersetze:

```dart
              Text(
                candidate.warnings.join(' '),
                style: TextStyle(color: Colors.orange.shade800, fontSize: 12),
              ),
```

durch:

```dart
              Text(
                candidate.warnings.join(' '),
                style: TextStyle(color: Colors.orange.shade300, fontSize: 12),
              ),
```

- [ ] **Step 3: `status_banner.dart` — Status-Farben aufhellen**

Öffne `mobile/lib/widgets/status_banner.dart`. Ersetze:

```dart
    final Color color = switch (status) {
      LoadStatus.error => Colors.red.shade700,
      LoadStatus.ok => Colors.green.shade700,
      _ => Colors.grey.shade700,
    };
```

durch:

```dart
    final Color color = switch (status) {
      LoadStatus.error => Colors.red.shade300,
      LoadStatus.ok => Colors.green.shade300,
      _ => Colors.grey.shade400,
    };
```

- [ ] **Step 4: `recording_control.dart` — Play/Pause als gefüllter Kreis-Button, Fehlertext
  aufhellen**

Öffne `mobile/lib/widgets/recording_control.dart`. Ersetze im Vorschau-`Row` (im `else`-Zweig
von `build()`) den Play/Pause-`IconButton`:

```dart
              IconButton(
                onPressed: _isBusy ? null : _togglePlayback,
                icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                tooltip: _isPlaying ? 'Pause' : 'Abspielen',
              ),
```

durch:

```dart
              IconButton.filled(
                onPressed: _isBusy ? null : _togglePlayback,
                icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                tooltip: _isPlaying ? 'Pause' : 'Abspielen',
              ),
```

(Nur diese eine Zeile `IconButton(` → `IconButton.filled(` ändern, Rest identisch. Der
Löschen-`IconButton` bleibt bewusst unverändert als normaler, nicht gefüllter Button.)

Ersetze außerdem die Fehlertext-Farbe:

```dart
            child: Text(_errorMessage!, style: TextStyle(color: Colors.red.shade700)),
```

durch:

```dart
            child: Text(_errorMessage!, style: TextStyle(color: Colors.red.shade300)),
```

- [ ] **Step 5: Statische Analyse**

Run: `cd mobile && flutter analyze`
Expected: "No issues found!"

- [ ] **Step 6: Bestehende Test-Suite gegenprüfen**

Run: `cd mobile && flutter test test/widget_test.dart` und
`flutter test test/session_state_test.dart` einzeln.
Expected: weiterhin 8/8 bestehend, unverändert.

- [ ] **Step 7: Commit**

```bash
git add mobile/lib/widgets/pitch_chart.dart mobile/lib/widgets/track_candidate_card.dart \
        mobile/lib/widgets/status_banner.dart mobile/lib/widgets/recording_control.dart
git commit -m "feat: adapt hardcoded widget colors to the dark/teal theme"
```

---

### Task 3: Visuelle Verifikation per Android-Emulator-Screenshot

**Files:** keine (reine Verifikation, keine Code-Änderung)

**Interfaces:**
- Consumes: laufender Android-Emulator (`emulator-5554`, bereits in dieser Session
  eingerichtet und gebootet — headless, KVM-beschleunigt, AVD-Name `redesign_test`),
  Backend-Instanz (`backend/main.py`, `--host 0.0.0.0`, bereits aktiv).

- [ ] **Step 1: App auf dem Emulator starten**

Run: `cd mobile && flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8000 -d
emulator-5554` (`10.0.2.2` ist der feste Loopback-Alias des Android-Emulators zum Host,
siehe `mobile/README.md`).

- [ ] **Step 2: Screenshot des Ausgangszustands**

Run: `adb -s emulator-5554 exec-out screencap -p >
/tmp/redesign-1-initial.png`

Screenshot ansehen (Read-Tool): dunkler Hintergrund (`#121111`), Teal-Akzente an
MIDI/Referenz-Umschalter und Buttons, abgerundete Pill-Form der Buttons, neue Schriftart
sichtbar.

- [ ] **Step 3: Screenshot mit Track-Kandidaten und Vorschau-Zustand**

MIDI-Testdatei hochladen (`tests/fixtures/test_reference.mid`, falls nötig vorher per
`python tests/fixtures/generate_fixtures.py` erzeugen und via `adb push` auf den Emulator
übertragen, oder direkt eine Aufnahme starten/stoppen um den Vorschau-Zustand von
`RecordingControl` zu erreichen). Screenshot: `adb -s emulator-5554 exec-out screencap -p >
/tmp/redesign-2-preview.png`. Prüfen: Track-Karten mit Teal-Tönung bei Auswahl, gefüllter
Teal-Kreis-Button für Play in der Aufnahme-Vorschau.

- [ ] **Step 4: Screenshot mit Pitch-Chart**

Nach einer abgeschlossenen Analyse (Ziel + Gesang vorhanden) Screenshot:
`adb -s emulator-5554 exec-out screencap -p > /tmp/redesign-3-chart.png`. Prüfen:
Zielkurve in Teal, Gesangskurve weiterhin Orange, guter Kontrast auf dunklem Hintergrund.

- [ ] **Step 5: Mit Figma-Referenz abgleichen**

Alle drei Screenshots gegen die Figma-Referenz (Farbwerte, Formsprache, Schrift-Charakter)
prüfen — nicht pixelgenau, aber im Gesamteindruck (dunkel, Teal-Akzente, runde Formen)
stimmig. Bei Abweichungen: zurück zu Task 1/2, gezielt nachbessern.

Expected: Alle drei Abschnitte wirken wie aus einem Guss im neuen Stil, keine hell-auf-hell
oder dunkel-auf-dunkel Lesbarkeitsprobleme, bestehende Funktionalität unangetastet.

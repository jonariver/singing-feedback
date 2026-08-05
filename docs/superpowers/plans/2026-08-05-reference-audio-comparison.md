# Eigene Referenzaufnahme statt MIDI (Mobile-App) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Der Flutter-Client (`mobile/`) bekommt neben dem bestehenden MIDI-Upload eine zweite
Möglichkeit, die Zielmelodie festzulegen: eine selbst bereitgestellte Referenzaufnahme (Datei
oder Live-Mikrofon), deren pYIN-Kurve wie die MIDI-Zielkurve im Pitch-Chart angezeigt und
transponiert werden kann.

**Architecture:** Kein Backend-Change. Der bestehende `POST /api/audio/analyze`-Endpunkt wird für
Referenz- und Versuchs-Aufnahme gleichermaßen genutzt. `SessionState` bekommt einen zweiten Modus
(`ReferenceSource.recording`), dessen roh gespeicherte Kurve bei jeder Transpose-Änderung rein
client-seitig (Hz × 2^(Halbtöne/12)) neu berechnet und in `TargetPoint`-Form (kompatibel zum
bestehenden Chart-Slot) angezeigt wird.

**Tech Stack:** Flutter/Dart (`mobile/`), `provider` (ChangeNotifier-State), `flutter_test`
(Unit- und Widget-Tests), bestehende `AudioApi`/`ApiClient`-Klassen (kein neues Package).

## Global Constraints

- Kein Backend-Endpunkt wird geändert oder neu angelegt (`backend/` bleibt unangetastet).
- Nur `mobile/` wird angepasst; `frontend/app.js` bleibt MIDI-only.
- Referenzaufnahme ist eine *Alternative neben* MIDI, nicht dessen Ersatz — bestehender
  MIDI-Pfad (Upload, Track-Auswahl, Server-seitiges Transpose) bleibt vollständig erhalten.
- Kein neues Flutter-Package (kein Mocking-Framework) — Test-Doubles werden von Hand
  geschrieben, wie im restlichen Projekt üblich.

---

## Datei-Übersicht

- **Modify:** `mobile/lib/state/session_state.dart` — neuer `ReferenceSource`-Enum, neue Felder/
  Methoden/Getter für den Referenz-Pfad.
- **Modify:** `mobile/lib/screens/home_screen.dart` — Umschalter UI, bedingte Anzeige MIDI- vs.
  Referenz-Abschnitt, Chart nutzt neuen Getter.
- **Create:** `mobile/test/session_state_test.dart` — Unit-Tests für den neuen State-Pfad.
- **Modify:** `mobile/test/widget_test.dart` — ein zusätzlicher Smoke-Test für den Umschalter.

---

### Task 1: State-Layer — `ReferenceSource`, Referenz-Kurve, transponierbarer Getter

**Files:**
- Modify: `mobile/lib/state/session_state.dart`
- Test: `mobile/test/session_state_test.dart` (neu)

**Interfaces:**
- Produces: `enum ReferenceSource { midi, recording }`; `SessionState.referenceSource`
  (`ReferenceSource`, Default `ReferenceSource.midi`); `SessionState.referenceRawCurve`
  (`List<SungPoint>`); `SessionState.referenceStatus` (`LoadStatus`);
  `SessionState.referenceMessage` (`String`); `SessionState.analyzeReference(Uint8List bytes,
  String filename) -> Future<void>`; `SessionState.setReferenceSource(ReferenceSource source) ->
  void`; `SessionState.displayedTargetCurve -> List<TargetPoint>` (Getter). Alle bestehenden
  Felder/Methoden (`targetCurve`, `sungCurve`, `uploadMidi`, `selectTrack`, `setTranspose`,
  `analyzeAudio`, `audioSectionEnabled`) bleiben in Signatur/Verhalten für den MIDI-Pfad
  unverändert.

- [ ] **Step 1: Schreibe die fehlschlagenden Tests**

Erstelle `mobile/test/session_state_test.dart`:

```dart
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:singing_feedback_mobile/api/api_client.dart';
import 'package:singing_feedback_mobile/api/audio_api.dart';
import 'package:singing_feedback_mobile/api/midi_api.dart';
import 'package:singing_feedback_mobile/models/target_point.dart';
import 'package:singing_feedback_mobile/state/session_state.dart';

class _FakeApiClient extends ApiClient {
  _FakeApiClient() : super(baseUrl: 'http://fake.local');

  @override
  Future<Map<String, dynamic>> postMultipart(
    String path, {
    required String fieldName,
    required Uint8List bytes,
    required String filename,
  }) async {
    return {
      'curve': [
        {'t': 0.0, 'hz': 440.0, 'voiced': true, 'confidence': 0.9},
        {'t': 0.01, 'hz': null, 'voiced': false, 'confidence': 0.0},
      ],
    };
  }
}

SessionState _buildSession() {
  final client = _FakeApiClient();
  return SessionState(midiApi: MidiApi(client), audioApi: AudioApi(client));
}

void main() {
  test('displayedTargetCurve liefert im MIDI-Modus targetCurve unveraendert', () {
    final session = _buildSession();
    session.targetCurve = const [TargetPoint(t: 0.0, hz: 220.0, midiNote: 57)];

    expect(session.referenceSource, ReferenceSource.midi);
    expect(session.displayedTargetCurve, session.targetCurve);
  });

  test('analyzeReference befuellt referenceRawCurve und displayedTargetCurve im Referenz-Modus', () async {
    final session = _buildSession();
    session.setReferenceSource(ReferenceSource.recording);

    await session.analyzeReference(Uint8List(0), 'referenz.wav');

    expect(session.referenceStatus, LoadStatus.ok);
    expect(session.referenceRawCurve.length, 2);
    expect(session.displayedTargetCurve[0].hz, closeTo(440.0, 0.001));
    expect(session.displayedTargetCurve[0].midiNote, isNull);
    expect(session.displayedTargetCurve[1].hz, isNull);
  });

  test('setTranspose verschiebt die Referenzkurve rein rechnerisch ohne erneuten Netzwerkaufruf', () async {
    final session = _buildSession();
    session.setReferenceSource(ReferenceSource.recording);
    await session.analyzeReference(Uint8List(0), 'referenz.wav');
    final curveBeforeTranspose = session.referenceRawCurve;

    await session.setTranspose(12);

    expect(session.transposeSemitones, 12);
    expect(session.displayedTargetCurve[0].hz, closeTo(440.0 * math.pow(2, 1), 0.01));
    // Keine erneute Analyse ausgeloest: dieselbe Roh-Kurven-Instanz wie vor dem Transpose.
    expect(identical(session.referenceRawCurve, curveBeforeTranspose), isTrue);
  });

  test('audioSectionEnabled haengt im Referenz-Modus von referenceRawCurve ab', () async {
    final session = _buildSession();
    session.setReferenceSource(ReferenceSource.recording);
    expect(session.audioSectionEnabled, isFalse);

    await session.analyzeReference(Uint8List(0), 'referenz.wav');
    expect(session.audioSectionEnabled, isTrue);
  });

  test('setReferenceSource wechselt zurueck ohne referenceRawCurve zu verwerfen', () async {
    final session = _buildSession();
    session.setReferenceSource(ReferenceSource.recording);
    await session.analyzeReference(Uint8List(0), 'referenz.wav');

    session.setReferenceSource(ReferenceSource.midi);
    session.setReferenceSource(ReferenceSource.recording);

    expect(session.referenceRawCurve.length, 2);
  });
}
```

- [ ] **Step 2: Tests laufen lassen, um das erwartete Fehlschlagen zu bestätigen**

Run: `cd mobile && flutter test test/session_state_test.dart`
Expected: FAIL — Compile-Fehler, da `ReferenceSource`, `referenceRawCurve`, `referenceStatus`,
`analyzeReference`, `setReferenceSource` und `displayedTargetCurve` in `session_state.dart` noch
nicht existieren.

- [ ] **Step 3: Implementiere `ReferenceSource` und die neuen State-Mitglieder**

Öffne `mobile/lib/state/session_state.dart`. Füge nach dem bestehenden Import-Block (vor `enum
LoadStatus`) den neuen Enum hinzu, und ergänze `import 'dart:math' as math;` ganz oben:

```dart
import 'dart:math' as math;
import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../api/audio_api.dart';
import '../api/midi_api.dart';
import '../models/sung_point.dart';
import '../models/target_point.dart';
import '../models/track_candidate.dart';

enum LoadStatus { idle, loading, ok, error }

enum ReferenceSource { midi, recording }
```

Ergänze in der `SessionState`-Klasse nach der bestehenden Feldliste (nach `String audioMessage =
'';`) die neuen Felder:

```dart
  ReferenceSource referenceSource = ReferenceSource.midi;
  List<SungPoint> referenceRawCurve = [];
  LoadStatus referenceStatus = LoadStatus.idle;
  String referenceMessage = '';
```

Ersetze den bestehenden Getter

```dart
  bool get audioSectionEnabled => selectedTrackIndex != null;
```

durch:

```dart
  bool get audioSectionEnabled => referenceSource == ReferenceSource.midi
      ? selectedTrackIndex != null
      : referenceRawCurve.isNotEmpty;

  List<TargetPoint> get displayedTargetCurve {
    if (referenceSource == ReferenceSource.midi) return targetCurve;
    return referenceRawCurve
        .map((p) => TargetPoint(
              t: p.t,
              hz: p.hz == null ? null : p.hz! * math.pow(2, transposeSemitones / 12),
              midiNote: null,
            ))
        .toList();
  }
```

Ersetze die bestehende `setTranspose`-Methode

```dart
  Future<void> setTranspose(int semitones) async {
    if (selectedTrackIndex == null) return;
    transposeSemitones = semitones;
    await _reloadTargetCurve();
  }
```

durch:

```dart
  Future<void> setTranspose(int semitones) async {
    if (referenceSource == ReferenceSource.recording) {
      transposeSemitones = semitones;
      notifyListeners();
      return;
    }
    if (selectedTrackIndex == null) return;
    transposeSemitones = semitones;
    await _reloadTargetCurve();
  }
```

Füge nach der bestehenden `analyzeAudio`-Methode (vor `_resetAudioSection`) die zwei neuen
Methoden ein:

```dart
  Future<void> analyzeReference(Uint8List bytes, String filename) async {
    referenceStatus = LoadStatus.loading;
    referenceMessage = 'Analysiere Referenzaufnahme…';
    notifyListeners();
    try {
      referenceRawCurve = await audioApi.analyzeAudio(bytes, filename);
      referenceStatus = LoadStatus.ok;
      referenceMessage =
          'Referenz analysiert. Jetzt eine Gesangsaufnahme aufnehmen oder hochladen.';
    } catch (e) {
      referenceStatus = LoadStatus.error;
      referenceMessage = 'Fehler: ${_messageOf(e)}';
    }
    notifyListeners();
  }

  void setReferenceSource(ReferenceSource source) {
    referenceSource = source;
    sungCurve = [];
    audioStatus = LoadStatus.idle;
    audioMessage = '';
    notifyListeners();
  }
```

- [ ] **Step 4: Tests laufen lassen, um das Bestehen zu bestätigen**

Run: `cd mobile && flutter test test/session_state_test.dart`
Expected: PASS (alle 5 Tests grün)

- [ ] **Step 5: Bestehende Tests gegenpruefen**

Run: `cd mobile && flutter test`
Expected: PASS (der bestehende `widget_test.dart`-Smoke-Test darf durch diese State-Änderung
nicht brechen, da `home_screen.dart` in diesem Task noch nicht angefasst wird)

- [ ] **Step 6: Commit**

```bash
cd mobile && git add lib/state/session_state.dart test/session_state_test.dart
git commit -m "feat: add reference-audio mode to SessionState"
```

---

### Task 2: UI-Layer — Umschalter, bedingte Anzeige, Chart auf `displayedTargetCurve` umstellen

**Files:**
- Modify: `mobile/lib/screens/home_screen.dart`
- Modify: `mobile/test/widget_test.dart`

**Interfaces:**
- Consumes: `SessionState.referenceSource`, `SessionState.setReferenceSource(ReferenceSource)`,
  `SessionState.referenceStatus`, `SessionState.referenceMessage`,
  `SessionState.analyzeReference(Uint8List, String)`, `SessionState.displayedTargetCurve`,
  `SessionState.audioSectionEnabled` (alle aus Task 1). Bestehende Widgets `RecordingControl`,
  `StatusBanner`, `TrackCandidateCard`, `TransposeControl`, `PitchChart` werden unverändert
  wiederverwendet (keine Widget-Datei wird in diesem Task angefasst).

- [ ] **Step 1: Schreibe den fehlschlagenden Widget-Test**

Ergänze `mobile/test/widget_test.dart` um einen zweiten Test (Datei bleibt ansonsten
unverändert):

```dart
import 'package:flutter_test/flutter_test.dart';

import 'package:singing_feedback_mobile/main.dart';

void main() {
  testWidgets('App startet und zeigt den Home-Screen', (WidgetTester tester) async {
    await tester.pumpWidget(const SingingFeedbackApp());

    expect(find.text('Singing Feedback'), findsOneWidget);
    expect(find.text('MIDI-Datei wählen'), findsOneWidget);
  });

  testWidgets(
      'Umschalter auf Referenzaufnahme ersetzt den MIDI-Picker durch eine zweite Aufnahme-Steuerung',
      (WidgetTester tester) async {
    await tester.pumpWidget(const SingingFeedbackApp());
    expect(find.text('Aufnehmen'), findsOneWidget);

    await tester.tap(find.text('Eigene Aufnahme'));
    await tester.pumpAndSettle();

    expect(find.text('MIDI-Datei wählen'), findsNothing);
    expect(find.text('Aufnehmen'), findsNWidgets(2));
  });
}
```

- [ ] **Step 2: Test laufen lassen, um das erwartete Fehlschlagen zu bestätigen**

Run: `cd mobile && flutter test test/widget_test.dart`
Expected: FAIL — der zweite Test findet `'Eigene Aufnahme'` nicht (Umschalter existiert noch
nicht), Tap schlägt fehl.

- [ ] **Step 3: Implementiere den Umschalter und die bedingte Anzeige**

Öffne `mobile/lib/screens/home_screen.dart`. Ersetze den Block von (aktuell) Zeile 40 bis Zeile
79 — beginnend bei `Text('1. MIDI-Referenzspur', ...)` bis zum schließenden `),` der
`PitchChart`-`SizedBox` — durch:

```dart
            Text('1. Zielmelodie', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            SegmentedButton<ReferenceSource>(
              segments: const [
                ButtonSegment(value: ReferenceSource.midi, label: Text('MIDI-Datei')),
                ButtonSegment(value: ReferenceSource.recording, label: Text('Eigene Aufnahme')),
              ],
              selected: {session.referenceSource},
              onSelectionChanged: (selection) => session.setReferenceSource(selection.first),
            ),
            const SizedBox(height: 8),
            if (session.referenceSource == ReferenceSource.midi) ...[
              ElevatedButton.icon(
                onPressed: () => _pickMidi(context),
                icon: const Icon(Icons.upload_file),
                label: const Text('MIDI-Datei wählen'),
              ),
              StatusBanner(status: session.midiStatus, message: session.midiMessage),
              ...session.candidates.map(
                (c) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TrackCandidateCard(
                    candidate: c,
                    selected: session.selectedTrackIndex == c.index,
                    onSelect: () => session.selectTrack(c.index),
                  ),
                ),
              ),
            ] else ...[
              RecordingControl(
                enabled: true,
                onAudioReady: (bytes, filename) => session.analyzeReference(bytes, filename),
              ),
              StatusBanner(status: session.referenceStatus, message: session.referenceMessage),
            ],
            if (session.audioSectionEnabled) ...[
              const SizedBox(height: 8),
              TransposeControl(
                value: session.transposeSemitones,
                onChanged: session.setTranspose,
              ),
            ],
            const Divider(height: 32),
            Text('2. Gesangsaufnahme', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            RecordingControl(
              enabled: session.audioSectionEnabled,
              onAudioReady: (bytes, filename) => session.analyzeAudio(bytes, filename),
            ),
            StatusBanner(status: session.audioStatus, message: session.audioMessage),
            const Divider(height: 32),
            Text('3. Tonhöhen-Vergleich', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            SizedBox(
              height: 300,
              width: double.infinity,
              child: PitchChart(
                targetCurve: session.displayedTargetCurve,
                sungCurve: session.sungCurve,
              ),
            ),
```

Ergänze außerdem den Import von `ReferenceSource` — da es in derselben Datei wie `SessionState`
definiert ist, ist der bestehende Import `import '../state/session_state.dart';` bereits
ausreichend; keine neue Import-Zeile nötig.

- [ ] **Step 4: Tests laufen lassen, um das Bestehen zu bestätigen**

Run: `cd mobile && flutter test`
Expected: PASS (alle Tests in `widget_test.dart` und `session_state_test.dart` grün)

- [ ] **Step 5: Statische Analyse**

Run: `cd mobile && flutter analyze`
Expected: "No issues found!"

- [ ] **Step 6: Commit**

```bash
cd mobile && git add lib/screens/home_screen.dart test/widget_test.dart
git commit -m "feat: add reference-audio toggle to home screen"
```

---

### Task 3: Manuelle End-to-End-Verifikation auf echtem Gerät

**Files:** keine (reine Verifikation, keine Code-Änderung)

**Interfaces:**
- Consumes: Backend-Instanz aus `backend/main.py` (bereits in dieser Session auf `0.0.0.0:8000`
  laufend), Android-Gerät via ADB-Wireless-Debugging (bereits in dieser Session gepaart, siehe
  vorherige Verifikation des Golden Path — Verbindung ggf. erneut per `adb connect
  192.168.178.60:33515` herstellen, falls die Session inzwischen getrennt wurde).

- [ ] **Step 1: Backend-Erreichbarkeit prüfen**

Run: `curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8000/`
Expected: `200` (falls nicht: Backend gemäß vorherigem Setup neu starten — `.venv/bin/python -m
uvicorn backend.main:app --host 0.0.0.0 --port 8000`)

- [ ] **Step 2: ADB-Verbindung zum Handy prüfen, ggf. neu verbinden**

Run: `adb devices`
Expected: Gerät `192.168.178.60:33515` mit Status `device`. Falls nicht gelistet: `adb connect
192.168.178.60:33515` erneut ausführen (Pairing bleibt i. d. R. über die Sitzung hinweg gültig,
nur der TCP-Connect muss ggf. wiederholt werden).

- [ ] **Step 3: App auf dem Handy starten**

Run: `cd mobile && flutter run --dart-define=API_BASE_URL=http://192.168.178.23:8000 -d
192.168.178.60:33515`

- [ ] **Step 4: Referenz-Modus manuell durchklicken**

Auf dem Handy: Umschalter auf "Eigene Aufnahme" tippen → per Mikrofon eine kurze Referenz
aufnehmen (oder `tests/fixtures/test_vocal.wav` als Referenzdatei wählen) → warten bis
`StatusBanner` "Referenz analysiert…" zeigt → Transpose-Slider einmal hoch- und
runterbewegen und prüfen, dass sich die blaue Zielkurve im Chart sichtbar verschiebt, ohne dass
im Backend-Log ein neuer `/api/audio/analyze`-Request auftaucht (nur der erste Request beim
Hochladen der Referenz sollte erscheinen) → danach im Abschnitt "2. Gesangsaufnahme" eine zweite
Aufnahme machen oder `tests/fixtures/test_vocal.wav` hochladen → prüfen, dass der Chart beide
Kurven (Referenz blau, Gesang orange) zeigt.

- [ ] **Step 5: Rückwechsel zu MIDI prüfen**

Umschalter zurück auf "MIDI-Datei" tippen → prüfen, dass der MIDI-Picker-Button wieder erscheint
und die Referenzaufnahme-Steuerung verschwindet → `tests/fixtures/test_reference.mid` hochladen
und den bestehenden MIDI-Flow einmal komplett durchspielen, um sicherzustellen, dass der
bestehende Pfad nicht beschädigt wurde.

Expected: Beide Modi funktionieren unabhängig voneinander, keine Abstürze, keine falschen
Chart-Daten.

---

## Self-Review-Notizen (bereits eingearbeitet)

- Spec-Abdeckung: Architektur/Datenfluss → Task 1 (Getter/Enum); State-Änderungen → Task 1
  vollständig; UI-Änderungen → Task 2 vollständig; Fehlerbehandlung → abgedeckt durch
  Wiederverwendung von `_messageOf`/`ApiException` in `analyzeReference` (Task 1, kein neuer
  Code nötig); Tests → Task 1 (State) + Task 2 (Widget-Smoke-Test), wie im Spec als "optional"
  vorgeschlagen, hier aber als vollwertiger Task-Schritt umgesetzt statt ausgelassen.
- Typ-Konsistenz geprüft: `ReferenceSource`, `referenceRawCurve`, `referenceStatus`,
  `referenceMessage`, `analyzeReference`, `setReferenceSource`, `displayedTargetCurve` werden in
  Task 1 definiert und in Task 2 mit identischer Signatur verwendet.
- Keine Platzhalter: alle Code-Blöcke sind vollständig, keine "ähnlich wie oben"-Verweise.

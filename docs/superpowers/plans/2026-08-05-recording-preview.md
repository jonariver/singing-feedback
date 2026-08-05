# Aufnahme abhören & löschen vor dem Hochladen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `RecordingControl` (`mobile/`) bekommt einen Vorschau-Schritt: nach einer
Mikrofonaufnahme oder Dateiauswahl kann der Nutzer erst anhören (Play/Pause) und
verwerfen (Löschen), bevor die Aufnahme tatsächlich hochgeladen/analysiert wird. Betrifft
automatisch beide Einsatzstellen des Widgets (Referenzaufnahme und Gesangsaufnahme).

**Architecture:** Rein interne State-Erweiterung von `RecordingControl` — die externe
Schnittstelle (`enabled`, `onAudioReady(bytes, filename)`) bleibt unverändert, nur der
Zeitpunkt des Aufrufs verschiebt sich vom Stopp/Dateiauswahl-Moment auf einen expliziten
"Verwenden"-Tap. Playback über das neue `audioplayers`-Package direkt aus den Bytes
(`BytesSource`), kein Zwischenspeichern auf Disk nötig.

**Tech Stack:** Flutter/Dart (`mobile/`), neues Package `audioplayers` für Wiedergabe,
bestehende Packages `record` (Aufnahme) und `file_picker` (Dateiauswahl) unverändert.

## Global Constraints

- Externe Schnittstelle von `RecordingControl` (`enabled`, `onAudioReady`-Signatur) bleibt
  unverändert — `home_screen.dart` wird in diesem Plan nicht angefasst.
- Gilt für Mikrofon-Aufnahmen UND per Datei-Picker ausgewählte Dateien gleichermaßen.
- Keine neue Test-Infrastruktur für Plattform-Channel-Mocking (`record`/`file_picker`/
  `audioplayers` sind alle Plattform-Channel-basiert und bereits heute ungetestet) —
  Verifikation dieses Plans erfolgt manuell auf einem echten Gerät, nicht per Widget-Test.
  Die bestehende automatisierte Test-Suite (aktuell 8/8 in `test/widget_test.dart` +
  `test/session_state_test.dart`) muss weiterhin unverändert grün bleiben, da dieser Plan
  ihr Verhalten nicht ändert.

---

## Datei-Übersicht

- **Modify:** `mobile/pubspec.yaml` — neue Abhängigkeit `audioplayers`.
- **Modify:** `mobile/lib/widgets/recording_control.dart` — Vorschau-Zustand, Play/Pause/
  Löschen/Verwenden-Logik.

---

### Task 1: `audioplayers`-Abhängigkeit + Vorschau-Zustand in `RecordingControl`

**Files:**
- Modify: `mobile/pubspec.yaml`
- Modify: `mobile/lib/widgets/recording_control.dart`

**Interfaces:**
- Consumes: nichts Neues aus anderen Dateien.
- Produces: keine neuen öffentlichen Symbole — `RecordingControl`s Konstruktor-Signatur
  (`enabled`, `onAudioReady`) bleibt exakt wie vorher, damit `home_screen.dart` (beide
  Aufrufstellen) unverändert bleibt.

- [ ] **Step 1: `audioplayers` zur pubspec.yaml hinzufügen**

Öffne `mobile/pubspec.yaml`. Füge unter `dependencies:` (nach dem `flutter: sdk: flutter`-
Block, vor `http: ^1.2.0`) diese Zeile ein:

```yaml
  audioplayers: ^6.0.0
```

Run: `cd mobile && flutter pub get`
Expected: `Got dependencies!` ohne Fehler, `audioplayers` erscheint in der Ausgabe.

- [ ] **Step 2: `recording_control.dart` um den Vorschau-Zustand erweitern**

Ersetze den kompletten Inhalt von `mobile/lib/widgets/recording_control.dart` durch:

```dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

/// Nimmt per Mikrofon auf oder laesst alternativ eine vorhandene Audiodatei waehlen
/// (Datei-Fallback = Paritaet mit dem heutigen <input type="file"> in app.js, das
/// Mikrofon selbst ist eine bewusste Ergaenzung fuer die Mobile-App). Vor dem Hochladen
/// kann die Aufnahme/Datei erst angehoert und verworfen werden - erst ein expliziter
/// "Verwenden"-Tap liefert (bytes, filename) an [onAudioReady], das denselben
/// POST /api/audio/analyze-Aufruf ausloest wie im Web-Frontend.
class RecordingControl extends StatefulWidget {
  final bool enabled;
  final void Function(Uint8List bytes, String filename) onAudioReady;

  const RecordingControl({super.key, required this.enabled, required this.onAudioReady});

  @override
  State<RecordingControl> createState() => _RecordingControlState();
}

class _RecordingControlState extends State<RecordingControl> {
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();
  late final StreamSubscription<void> _playerCompleteSubscription;
  bool _isRecording = false;
  bool _isPlaying = false;
  Uint8List? _pendingAudio;
  String? _pendingFilename;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _playerCompleteSubscription = _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _isPlaying = false);
    });
  }

  @override
  void dispose() {
    _playerCompleteSubscription.cancel();
    _recorder.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<void> _startRecording() async {
    setState(() => _errorMessage = null);
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      setState(() => _errorMessage = 'Mikrofon-Berechtigung wurde nicht erteilt.');
      return;
    }

    final dir = await Directory.systemTemp.createTemp('singing_feedback_');
    final path = '${dir.path}/aufnahme.m4a';
    // Explizit AAC/M4A statt Paket-Default: beide Plattformen (Android MediaRecorder,
    // iOS AVAudioRecorder) unterstuetzen das nativ, und der PyAV-Fallback in
    // backend/pitch_detection/pyin.py deckt .m4a-Dekodierung serverseitig ab.
    await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
    setState(() => _isRecording = true);
  }

  Future<void> _stopRecording() async {
    final path = await _recorder.stop();
    setState(() => _isRecording = false);
    if (path == null) return;
    final bytes = await File(path).readAsBytes();
    setState(() {
      _pendingAudio = bytes;
      _pendingFilename = 'aufnahme.m4a';
    });
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['wav', 'mp3', 'flac', 'ogg', 'm4a', 'webm'],
      withData: true,
    );
    final file = result?.files.single;
    if (file?.bytes == null) return;
    setState(() {
      _pendingAudio = file!.bytes!;
      _pendingFilename = file.name;
    });
  }

  Future<void> _togglePlayback() async {
    try {
      if (_isPlaying) {
        await _player.pause();
        setState(() => _isPlaying = false);
      } else {
        await _player.play(BytesSource(_pendingAudio!));
        setState(() => _isPlaying = true);
      }
    } catch (e) {
      setState(() => _errorMessage = 'Wiedergabe fehlgeschlagen: $e');
    }
  }

  Future<void> _discard() async {
    if (_isPlaying) {
      await _player.stop();
    }
    setState(() {
      _pendingAudio = null;
      _pendingFilename = null;
      _isPlaying = false;
    });
  }

  Future<void> _confirm() async {
    final bytes = _pendingAudio;
    final filename = _pendingFilename;
    if (bytes == null || filename == null) return;
    if (_isPlaying) {
      await _player.stop();
    }
    setState(() {
      _pendingAudio = null;
      _pendingFilename = null;
      _isPlaying = false;
    });
    widget.onAudioReady(bytes, filename);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_pendingAudio == null)
          Row(
            children: [
              ElevatedButton.icon(
                onPressed:
                    widget.enabled ? (_isRecording ? _stopRecording : _startRecording) : null,
                icon: Icon(_isRecording ? Icons.stop : Icons.mic),
                label: Text(_isRecording ? 'Aufnahme stoppen' : 'Aufnehmen'),
              ),
              const SizedBox(width: 12),
              TextButton.icon(
                onPressed: widget.enabled && !_isRecording ? _pickFile : null,
                icon: const Icon(Icons.folder_open),
                label: const Text('Datei wählen'),
              ),
            ],
          )
        else
          Row(
            children: [
              IconButton(
                onPressed: _togglePlayback,
                icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                tooltip: _isPlaying ? 'Pause' : 'Abspielen',
              ),
              IconButton(
                onPressed: _discard,
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Löschen',
              ),
              const SizedBox(width: 12),
              ElevatedButton(
                onPressed: _confirm,
                child: const Text('Verwenden'),
              ),
            ],
          ),
        if (_errorMessage != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(_errorMessage!, style: TextStyle(color: Colors.red.shade700)),
          ),
      ],
    );
  }
}
```

- [ ] **Step 3: Statische Analyse**

Run: `cd mobile && flutter analyze`
Expected: "No issues found!"

- [ ] **Step 4: Bestehende Test-Suite gegenprüfen**

Run: `cd mobile && flutter test test/widget_test.dart test/session_state_test.dart` (bei
verwirrend wirkender kombinierter Ausgabe — bekannter Flutter-Test-Runner-Anzeigefehler bei
mehreren Dateien, siehe Global Constraints — beide Dateien stattdessen einzeln laufen lassen:
`flutter test test/widget_test.dart` und `flutter test test/session_state_test.dart`)
Expected: weiterhin 8/8 bestehend (2 in `widget_test.dart`, 6 in `session_state_test.dart`),
unverändert gegenüber vor diesem Task — dieser Task ändert kein Verhalten, das diese Tests
prüfen.

- [ ] **Step 5: Commit**

```bash
git add mobile/pubspec.yaml mobile/pubspec.lock mobile/lib/widgets/recording_control.dart
git commit -m "feat: add listen-back/discard preview before uploading a recording"
```

---

### Task 2: Manuelle End-to-End-Verifikation auf echtem Gerät

**Files:** keine (reine Verifikation, keine Code-Änderung)

**Interfaces:**
- Consumes: Backend-Instanz (`backend/main.py`, `--host 0.0.0.0`), Android-Gerät via
  ADB-Wireless-Debugging — beide bereits aus vorherigen Sessions bekannt; Verbindungsdaten
  (Connect-Port) ändern sich pro Sitzung, siehe ggf. erneutes `adb connect <ip>:<port>`.

- [ ] **Step 1: Backend & Gerät erreichbar machen**

Backend starten falls nicht mehr aktiv: `.venv/bin/python -m uvicorn backend.main:app --host
0.0.0.0 --port 8000`. ADB-Verbindung prüfen: `adb devices` — falls leer, `adb connect
<phone-ip>:<aktueller-connect-port>` (Port vom "Kabelloses Debugging"-Screen auf dem Handy
ablesen, ändert sich bei jeder Neuverbindung).

- [ ] **Step 2: App auf dem Handy starten**

Run: `cd mobile && flutter run --dart-define=API_BASE_URL=http://192.168.178.23:8000 -d
<device-id>`

- [ ] **Step 3: Mikrofon-Aufnahme-Vorschau prüfen (Gesangsaufnahme, Abschnitt 2)**

Auf dem Handy: bei "2. Gesangsaufnahme" auf "Aufnehmen" tippen, kurz sprechen/singen, auf
"Aufnahme stoppen" tippen. Erwartet: statt sofortigem Hochladen erscheinen jetzt Play/Pause-,
Löschen- und "Verwenden"-Buttons. Play antippen → Wiedergabe der eigenen Stimme hörbar, Icon
wechselt zu Pause. Erneut antippen → pausiert. Löschen antippen → zurück zu
Aufnehmen/Datei-wählen-Buttons, kein Request im Backend-Log. Neu aufnehmen, diesmal
"Verwenden" antippen → Upload/Analyse läuft wie bisher (Request im Backend-Log,
`StatusBanner` zeigt Analyseergebnis).

- [ ] **Step 4: Datei-Auswahl-Vorschau prüfen**

"Datei wählen" antippen, eine vorhandene Audiodatei auswählen. Erwartet: dieselbe
Vorschau-Zeile (Play/Pause/Löschen/Verwenden) erscheint statt sofortigem Upload. Play/Löschen
wie in Schritt 3 prüfen, dann "Verwenden" → Upload läuft.

- [ ] **Step 5: Referenzaufnahme-Abschnitt gegenprüfen**

Im Umschalter oben auf "Eigene Aufnahme" wechseln (Abschnitt 1) und Schritt 3 dort wiederholen
— derselbe Vorschau-Flow muss identisch funktionieren, da beide Abschnitte dasselbe
`RecordingControl`-Widget nutzen.

Expected: In allen drei Stellen (Referenzaufnahme, Gesangsaufnahme, Datei-Auswahl) verhält
sich die Vorschau identisch, keine Abstürze, kein Hochladen vor explizitem "Verwenden".

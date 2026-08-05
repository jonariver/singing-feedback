# Singing Feedback — Mobile-Client (Flutter)

Android/iOS-Client fuer den Singing-Feedback-Prototyp, siehe `../docs/mobile-port-notes.md`
(Ansatz D: das FastAPI-Backend bleibt fachlich unveraendert und wird gehostet statt nur lokal
zu laufen; dieser Client spricht es ueber die bestehende REST-API an). Feature-Paritaet mit
`../frontend/app.js` (Phase 1: MIDI hochladen, Spur waehlen, Aufnahme analysieren, Kurven
gegenueberstellen), plus Mikrofonaufnahme und einen Transpositions-Regler als bewusste
Ergaenzungen.

## Status

Flutter-SDK (`~/flutter`, stable), Android SDK (`~/Android/sdk`, Platform 36 + 35 +
build-tools 28.0.3/35.0.0, per Cmdline-Tools) und Java 17 sind eingerichtet.
`android/`+`ios/`-Plattformordner sind per `flutter create --platforms=android,ios .`
erzeugt, Mikrofon-/Internet-Berechtigungen (siehe unten) sind eingetragen.
**`flutter analyze`, `flutter test` und `flutter build apk --debug` laufen alle drei
erfolgreich durch** — die App wurde tatsaechlich zu einer installierbaren APK gebaut
(`build/app/outputs/flutter-apk/app-debug.apk`), nicht nur statisch geprueft.

**Bekannter, bewusst gewaehlter Workaround: `file_picker`-Version.** Dieses Flutter-SDK
(3.44.8, AGP 9.0.1) befindet sich in Flutters "Built-in Kotlin"-Migration (siehe
https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin). Aktuelle
`file_picker`-Versionen (>=11.0.0) ueberspringen bei AGP>=9 bewusst das explizite Anwenden
des Kotlin-Gradle-Plugins und verlassen sich auf AGPs eingebaute Kotlin-Unterstuetzung -
die in dieser Konfiguration aber nicht greift (die `compileDebugKotlin`-Task fuer
`:file_picker` fehlt komplett im Gradle-Taskgraph, wodurch `FilePickerPlugin.kt` nie
kompiliert wird und `GeneratedPluginRegistrant.java` mit "cannot find symbol
FilePickerPlugin" scheitert). Deshalb ist `file_picker` bewusst auf `10.3.10` gepinnt
(letzte Version, die das Kotlin-Plugin noch bedingungslos selbst anwendet, siehe
`pubspec.yaml`) statt auf `^11.0.0` - das bedeutet auch, dass der Code die aeltere
`FilePicker.platform.pickFiles(...)`-API nutzt (in 11.x waere es das statische
`FilePicker.pickFiles(...)`, siehe `lib/screens/home_screen.dart` und
`lib/widgets/recording_control.dart`). Sobald eine `file_picker`-Version erscheint, die
mit Built-in Kotlin funktioniert (oder eine neue Flutter-Version das AGP9-Verhalten
korrigiert), kann wieder auf `^11.0.0`+ hochgezogen werden - dann auch beide
`.platform.`-Aufrufe wieder auf die statische API umstellen.

`android/app/build.gradle.kts` setzt zusaetzlich `compileSdk = 36` explizit (statt
`flutter.compileSdkVersion` zu vertrauen), weil eine Plugin-Abhaengigkeit
(`flutter_plugin_android_lifecycle`) das mindestens verlangt.

**Noch offen:**
- **iOS-Builds sind auf Linux/WSL2 grundsaetzlich nicht moeglich** — dafuer wird ein Mac mit
  Xcode gebraucht (Flutter selbst ist plattformuebergreifend, aber das iOS-Toolchain-Build
  laeuft nur unter macOS).
- Getestet wurde bisher nur der Build (`flutter build apk`), nicht der App-Start auf einem
  echten Geraet/Emulator (WSL2 hat hier weder GUI-Emulator noch angeschlossenes Handy).
  Naechster Schritt: Handy per USB (z.B. via `usbipd-win` unter WSL2) oder WLAN-Debugging
  verbinden, `adb devices` pruefen, dann `flutter run`.

## Naechste Schritte zum Ausprobieren

1. **Gegen lokales Backend testen**: Backend mit `--host 0.0.0.0` starten (statt nur
   `127.0.0.1`, siehe `../run.py`/Haupt-README), dann:
   ```bash
   flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8000   # Android-Emulator
   flutter run --dart-define=API_BASE_URL=http://127.0.0.1:8000  # iOS-Simulator
   ```
   Fuer ein echtes Geraet im selben WLAN die LAN-IP des Rechners verwenden, der das Backend
   hostet, statt `10.0.2.2`/`127.0.0.1`.

## Berechtigungen (bereits eingetragen)

**Android** (`android/app/src/main/AndroidManifest.xml`):
```xml
<uses-permission android:name="android.permission.RECORD_AUDIO"/>
<uses-permission android:name="android.permission.INTERNET"/>
```

**iOS** (`ios/Runner/Info.plist`):
```xml
<key>NSMicrophoneUsageDescription</key>
<string>Wird benoetigt, um deine Gesangsaufnahme mit der MIDI-Referenzspur zu vergleichen.</string>
```

## Struktur

```
lib/
  config/app_config.dart   Backend-Basis-URL (per --dart-define=API_BASE_URL ueberschreibbar)
  api/                      ApiClient (generisch) + MidiApi/AudioApi (typisierte Wrapper)
  models/                   Spiegeln die Backend-JSON-Formen 1:1
  state/session_state.dart  ChangeNotifier, spiegelt das `state`-Objekt aus app.js
  screens/home_screen.dart  Einziger Screen, kompletter Ablauf
  widgets/                  TrackCandidateCard, TransposeControl, RecordingControl,
                             PitchChart (CustomPainter, 1:1-Port von drawChart()/drawCurve())
```

Wenn spaetere Backend-Phasen (DTW-Sync, Scoring, Claude-Feedback, siehe `../PLAN.md`) neue
Endpunkte bringen, kommen dafuer weitere `*Api`-Klassen neben `MidiApi`/`AudioApi` dazu, ohne
`ApiClient` anzufassen.

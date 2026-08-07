# Design: Wakelock während der Aufnahme

**Datum:** 2026-08-07
**Status:** Genehmigt, bereit für Plan

## Kontext

Live-Test auf dem Handy: Eine Aufnahme verlor ab Sekunde ~36 für ~14 Sekunden
Audio (bestätigt sowohl beim Abspielen als auch im nachträglichen Pitch-Chart —
eine gemeinsame Root Cause, da der Chart erst nach dem Hochladen aus der
fertigen `.m4a`-Datei erzeugt wird, nicht live). Nutzer bestätigte: das Display
ist während der Aufnahme ausgegangen (typischer Android-Display-Timeout).

`mobile/lib/widgets/recording_control.dart` hat aktuell keinerlei
Lifecycle-Behandlung — kein `WidgetsBindingObserver`, kein Wakelock, kein
Foreground-Service (Android), kein `UIBackgroundModes` (iOS). Startet der
native `MediaRecorder`/`AVAudioRecorder` einmalig per `_recorder.start(...)`
und schreibt kontinuierlich bis `_recorder.stop()`, kann eine
Display-Sperre/Audiofokus-Unterbrechung die Aufnahme lautlos lückenhaft
machen, ohne dass die App das bemerkt.

## Architektur

**Paket:** `wakelock_plus` (aktiv gepflegter Nachfolger von `wakelock`,
unterstützt Android + iOS) als neue Abhängigkeit in `mobile/pubspec.yaml`.

**Scope:** Nur Wakelock (Display bleibt während der Aufnahme an). Keine
Erkennung/Warnung bei Unterbrechungen, kein Foreground-Service, kein
`WidgetsBindingObserver` — bewusst nicht Teil dieser Spec (siehe "Out of
Scope").

### Referenzzähler statt 1:1 enable/disable

`home_screen.dart` rendert **zwei** unabhängige `RecordingControl`-Instanzen
gleichzeitig (Referenz- und Gesangsaufnahme-Abschnitt), jede mit eigenem
`_RecordingControlState`. Ein naives "enable bei `_startRecording`, disable
bei `_stopRecording`" pro Instanz wäre falsch: stoppt eine Instanz ihre
Aufnahme, während die andere (theoretisch) noch aufnimmt, würde der Wakelock
fälschlich deaktiviert.

Lösung: ein statischer Zähler auf Klassenebene in
`_RecordingControlState`, geteilt von allen Instanzen:

```dart
class _RecordingControlState extends State<RecordingControl> {
  static int _activeRecordings = 0;
  bool _holdsWakelock = false; // Instanz-Flag, verhindert doppeltes Dekrementieren
  // ...
}
```

- `_startRecording()`, nach erfolgreichem `_recorder.start(...)`: Zähler
  inkrementieren, `_holdsWakelock = true`. Geht der Zähler von 0 auf 1,
  `WakelockPlus.enable()` aufrufen.
- `_stopRecording()`, nach `_recorder.stop()`: falls `_holdsWakelock`, Zähler
  dekrementieren, `_holdsWakelock = false`. Fällt der Zähler auf 0,
  `WakelockPlus.disable()` aufrufen.
- `dispose()`: Sicherheitsnetz — falls `_holdsWakelock` beim Entsorgen noch
  gesetzt ist (Widget wird während laufender Aufnahme entfernt), dieselbe
  Dekrement-Logik wie in `_stopRecording()` ausführen, damit der Zähler nicht
  hängen bleibt und der Wakelock nicht dauerhaft aktiv bleibt.

Der Zähler-Mechanismus selbst (increment/decrement/enable-disable-Schwellen)
wird in eine kleine eigenständige Klasse extrahiert, `RecordingWakelock`
(neue Datei `mobile/lib/util/recording_wakelock.dart`), die die
`WakelockPlus`-Aufrufe kapselt:

```dart
class RecordingWakelock {
  static int _activeRecordings = 0;

  static Future<void> acquire() async {
    _activeRecordings++;
    if (_activeRecordings == 1) {
      await WakelockPlus.enable();
    }
  }

  static Future<void> release() async {
    if (_activeRecordings == 0) return;
    _activeRecordings--;
    if (_activeRecordings == 0) {
      await WakelockPlus.disable();
    }
  }
}
```

`_RecordingControlState` ruft `RecordingWakelock.acquire()`/`release()` auf
(mit dem `_holdsWakelock`-Instanzflag wie oben beschrieben, um doppeltes
`release()` pro Instanz zu verhindern). Diese Trennung macht den Zähler ohne
`WakelockPlus`-Plattform-Bridge testbar (Unit-Test gegen `RecordingWakelock`
direkt, mit einem austauschbaren Enable/Disable-Hook für den Test — Details
im Plan).

## Testing

- `RecordingWakelock`: Unit-Test verifiziert, dass zwei `acquire()`-Aufrufe
  genau einen Enable-Effekt auslösen, und erst der zweite `release()`-Aufruf
  (nachdem beide `acquire()` erfolgt sind) den Disable-Effekt auslöst. Ein
  einzelnes `acquire()`/`release()`-Paar löst je einen Enable/Disable aus.
  Ein `release()` ohne vorheriges `acquire()` ist ein No-op (schützt gegen
  das `dispose()`-Sicherheitsnetz bei einer Instanz, die nie aufgenommen
  hat).
- `recording_control.dart`: bestehende Widget-Tests (falls vorhanden) bleiben
  unverändert lauffähig; kein neuer Widget-Test nötig, da die Logik in
  `RecordingWakelock` getestet wird und die Verdrahtung in
  `_RecordingControlState` trivial ist (Aufruf an bekannten Stellen).

## Out of Scope (bewusst nicht Teil dieser Spec)

- Keine Erkennung/Warnung, falls die Aufnahme trotz Wakelock unterbrochen
  wird (z. B. eingehender Anruf, manueller Power-Button-Druck) — deckt den
  bestätigten Fall (Display-Timeout) nicht ab, war explizite Nutzerwahl.
- Kein Android-Foreground-Service, keine iOS-`UIBackgroundModes`-Erweiterung
  — Aufnahme bleibt an "App im Vordergrund" gebunden, wie bisher.
- Kein `WidgetsBindingObserver`/App-Lifecycle-Handling.

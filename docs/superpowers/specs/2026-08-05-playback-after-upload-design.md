# Aufnahme nach dem Hochladen anhören

Status: Design abgestimmt am 2026-08-05, bereit für Implementierungsplan.

## Kontext

Das Abhören/Löschen-Feature (siehe `2026-08-05-recording-preview-design.md`) erlaubt Vorschau
*vor* dem Hochladen, hat aber bewusst offen gelassen, ob die Aufnahme auch *nach* dem Hochladen
noch anhörbar sein soll (`_confirm()` in `RecordingControl` verwirft `_pendingAudio` sofort nach
dem Aufruf von `onAudioReady`). Der Nutzer möchte diese Lücke jetzt schließen.

**Scope-Entscheidungen (mit Nutzer geklärt):**
- Gilt für beide Aufnahme-Stellen (Referenz und Gesang) — konsistent mit dem
  Abhören-vor-Upload-Feature.
- Reine Wiedergabe-Funktion, kein Löschen der bereits hochgeladenen Aufnahme/Kurve — eine neue
  Aufnahme ersetzt die alte automatisch.
- Ansatz B (Bytes in `SessionState` statt widget-lokal in `RecordingControl`) gewählt, weil die
  `RecordingControl`-Instanz im Referenz-Abschnitt beim Umschalten zwischen "Eigene Aufnahme"/
  "MIDI-Datei" unmountet wird (bekannt aus einem früheren Review) — widget-lokaler State würde
  bei jedem Wechsel verloren gehen, `SessionState` überlebt das.

## Architektur & State (`mobile/lib/state/session_state.dart`)

Neue Felder, die demselben Persistenz-Muster wie die schon vorhandenen `referenceRawCurve`/
`sungCurve` folgen:
- `Uint8List? referenceAudioBytes` — gesetzt in `analyzeReference()`, **nicht** zurückgesetzt bei
  `setReferenceSource()`-Wechsel (wie `referenceRawCurve` heute schon persistiert).
- `Uint8List? sungAudioBytes` — gesetzt in `analyzeAudio()`, zurückgesetzt in
  `_resetAudioSection()` und in `setReferenceSource()` (wie `sungCurve` heute schon bei "neuer
  Durchlauf" geleert wird).

Beide werden unabhängig vom Analyse-Ergebnis gesetzt (auch bei fehlgeschlagener Pitch-Erkennung),
damit die Aufnahme trotzdem anhörbar bleibt.

## Neues Widget (`mobile/lib/widgets/playback_button.dart`)

`PlaybackButton` — nimmt `Uint8List? audioBytes` entgegen:
- `null` → rendert nichts (`SizedBox.shrink()`).
- sonst → Play/Pause-`IconButton` mit eigenem `AudioPlayer`, gleiches `_isBusy`-Guard-Muster wie
  in `RecordingControl` (synchrones Check-and-Set vor jedem `await`, Reset in `finally`) — aus
  dem letzten Feature übernommen, um dieselbe Race-Klasse von Anfang an zu vermeiden.
- `didUpdateWidget`: stoppt laufende Wiedergabe und setzt den Play/Pause-Zustand zurück, wenn
  sich `audioBytes` ändert (neue Aufnahme kam rein, alte Wiedergabe wird ungültig).
- Play-Fehler landen in einem eigenen kleinen `_errorMessage`-Feld, angezeigt als kleiner Text
  neben dem Button — gleiches Muster wie in `RecordingControl`, kein neuer Mechanismus.

## UI-Platzierung (`mobile/lib/screens/home_screen.dart`)

`StatusBanner` und `PlaybackButton` wandern in beiden Abschnitten in eine `Row` (Status-Text
links, Play-Icon rechts daneben):

```dart
Row(
  children: [
    Expanded(child: StatusBanner(status: session.referenceStatus, message: session.referenceMessage)),
    PlaybackButton(audioBytes: session.referenceAudioBytes),
  ],
),
```

(analog für Abschnitt 2 mit `session.audioStatus`/`session.audioMessage`/`session.sungAudioBytes`)

## Tests

Kein automatisierter Test für `PlaybackButton` selbst (Plattform-Channel-basiert, gleiche
Begründung wie bei `RecordingControl`). Ein State-Test für `SessionState`: prüft, dass
`sungAudioBytes`/`referenceAudioBytes` nach `analyzeAudio`/`analyzeReference` korrekt gesetzt
sind, dass `sungAudioBytes` beim `setReferenceSource`-Wechsel zurückgesetzt wird, aber
`referenceAudioBytes` nicht (das persistente Verhalten, das Ansatz B sicherstellen soll).
Bestehende Suite bleibt grün.

## Out of Scope (bewusst nicht Teil dieses Designs)

- Kein Löschen der bereits hochgeladenen Aufnahme/Kurve.
- Kein Backend-Change.
- `home_screen.dart`s sonstige Struktur bleibt unverändert.

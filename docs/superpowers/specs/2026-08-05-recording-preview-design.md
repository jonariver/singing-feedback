# Aufnahme abhören & löschen vor dem Hochladen (Mobile-App)

Status: Design abgestimmt am 2026-08-05, bereit für Implementierungsplan.

## Kontext

`RecordingControl` (`mobile/lib/widgets/recording_control.dart`) wird sowohl für die
Referenzaufnahme (Abschnitt 1, Referenz-Modus) als auch für die eigentliche Gesangsaufnahme
(Abschnitt 2) verwendet. Aktuell löst ein Stopp der Mikrofonaufnahme oder eine Dateiauswahl
sofort `onAudioReady` aus, was direkt den Upload/die Pitch-Analyse anstößt — es gibt keine
Möglichkeit, die Aufnahme vorher anzuhören oder zu verwerfen. Das fiel beim manuellen Testen
des vorherigen Features auf ("was mir auffällt: wenn ich was aufgenommen habe möchte ich die
Möglichkeit haben es mir danach anzuhören aber auch zu löschen").

**Scope-Entscheidungen (mit Nutzer geklärt):**
- Gilt für beide Stellen (Referenz- und Gesangsaufnahme) — da beide dasselbe
  `RecordingControl`-Widget nutzen, folgt das automatisch aus einer Widget-Änderung.
- Gilt sowohl für Mikrofon-Live-Aufnahmen als auch für per Datei-Picker ausgewählte Dateien.
- Ansatz A (siehe unten) — `RecordingControl` intern erweitern statt ein neues Widget
  einzuführen — wurde gegenüber zwei Alternativen (`just_audio` statt `audioplayers`; ein
  separates `RecordingPreview`-Widget mit geänderter Callback-Signatur) bevorzugt: kleinster
  Diff, keine Änderung an `home_screen.dart` nötig.

## Architektur & Datenfluss

Kein Backend-Change, kein `home_screen.dart`-Change. Die externe Schnittstelle von
`RecordingControl` (`enabled`, `onAudioReady(Uint8List bytes, String filename)`) bleibt exakt
gleich — `onAudioReady` wird nur später ausgelöst als heute: erst nach explizitem "Verwenden"
statt sofort nach Stopp/Dateiauswahl.

Neuer interner Ablauf:
```
Aufnehmen/Datei wählen
  → Bytes liegen vor, werden NICHT sofort hochgeladen
  → _pendingAudio/_pendingFilename gesetzt, Widget wechselt auf Vorschau-Ansicht
  → Play/Pause (audioplayers, BytesSource — kein Zwischenspeichern auf Disk nötig)
  → Löschen → zurück zum Ausgangszustand, nichts hochgeladen
  → Verwenden → jetzt erst onAudioReady(bytes, filename), danach zurück zum Ausgangszustand
```

Neue Abhängigkeit: `audioplayers: ^6.0.0` (Standard-Package für kurze Audio-Vorschau,
`BytesSource` spielt direkt aus dem Byte-Array ohne Zwischenspeicherung).

## Widget-State (`mobile/lib/widgets/recording_control.dart`)

- Neue Felder: `Uint8List? _pendingAudio`, `String? _pendingFilename`, `AudioPlayer _player =
  AudioPlayer()`, `bool _isPlaying = false`.
- `_stopRecording()`: setzt statt direktem `widget.onAudioReady(...)`-Aufruf nur noch
  `_pendingAudio`/`_pendingFilename` (Reset von `_isRecording` unverändert).
- `_pickFile()`: analog — setzt `_pendingAudio`/`_pendingFilename` statt direkt hochzuladen.
- Neue Methoden:
  - `_togglePlayback()`: `_player.play(BytesSource(_pendingAudio!))` bzw. `_player.pause()`,
    mit einem `_player.onPlayerComplete`-Listener, der `_isPlaying` auf `false` zurücksetzt,
    wenn die Wiedergabe von selbst endet.
  - `_discard()`: stoppt den Player falls aktiv, setzt `_pendingAudio`/`_pendingFilename` auf
    `null` (zurück zum Ausgangszustand).
  - `_confirm()`: ruft `widget.onAudioReady(_pendingAudio!, _pendingFilename!)` auf, setzt
    danach `_pendingAudio`/`_pendingFilename` auf `null` zurück (Widget ist wieder im
    Ausgangszustand für einen neuen Take).
- `dispose()`: zusätzlich `_player.dispose()` (neben dem bestehenden `_recorder.dispose()`).
- Play-Fehler (z. B. nicht abspielbares Format) landen im bestehenden
  `_errorMessage`-Mechanismus — kein neuer Fehlerpfad.

## UI

`build()` unterscheidet zwei Zustände:
- `_pendingAudio == null`: wie heute — Aufnehmen-/Datei-wählen-Buttons.
- `_pendingAudio != null`: eine Zeile mit Play/Pause-`IconButton`, Löschen-`IconButton`
  (Papierkorb-Icon), "Verwenden"-`ElevatedButton`.

`enabled` gilt weiterhin nur für den Start (Aufnehmen/Datei wählen); die Vorschau-Aktionen
(Play/Löschen/Verwenden) sind davon unabhängig bedienbar, sobald etwas vorliegt.

`home_screen.dart` bleibt komplett unverändert — beide `RecordingControl`-Instanzen
(Referenz- und Gesangsaufnahme) profitieren automatisch, ohne dass der Screen etwas davon
wissen muss.

## Fehlerbehandlung

Play-Fehler werden abgefangen und im bestehenden `_errorMessage`-Text angezeigt, exakt wie der
vorhandene Mikrofon-Berechtigungsfehler heute schon funktioniert.

## Tests

`RecordingControl` hat heute keine automatisierten Tests, weil `record` und `file_picker`
echte Plattform-Channels nutzen, die sich in einem Flutter-Widget-Test nicht ohne
Mock-Infrastruktur sinnvoll testen lassen; `audioplayers` hat dasselbe Problem. Bewusste
Entscheidung: kein Test-Infrastruktur-Umbau als Nebenschauplatz für dieses Feature — stattdessen
manuelle Verifikation auf einem echten Gerät (aufnehmen → abspielen → löschen → Buttons
erscheinen wieder → neu aufnehmen → "Verwenden" → Upload/Analyse läuft wie bisher).

## Out of Scope (bewusst nicht Teil dieses Designs)

- Kein Playback nach dem Upload (nur der Zustand vor dem Hochladen betroffen).
- Keine Änderung an `home_screen.dart`, `session_state.dart` oder dem Backend.
- Keine Test-Infrastruktur für Plattform-Channel-Mocking (siehe Tests-Abschnitt).

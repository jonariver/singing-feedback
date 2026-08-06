# Gesangsaufnahme teilen (Mobile-App)

Status: Design abgestimmt am 2026-08-06, bereit für Implementierungsplan.

## Kontext

Der Mobile-Client kann eine bereits hochgeladene Aufnahme seit dem "Aufnahme nach dem
Hochladen anhören"-Feature per `PlaybackButton` erneut abspielen (siehe
[[project_mobile_client]]). Der Nutzer möchte diese Aufnahme jetzt auch direkt aus der
App heraus teilen können — z.B. über WhatsApp oder andere Messenger — statt sie manuell
aus dem Dateisystem suchen zu müssen.

**Scope-Entscheidungen (mit Nutzer geklärt):**
- Nur die **Gesangsaufnahme** (Abschnitt "2. Gesangsaufnahme") bekommt einen
  Teilen-Button — nicht die Referenzaufnahme. Kleinster, klarster Umfang für den
  eigentlichen Anwendungsfall.
- **Kein Begleittext** — nur die Audiodatei wird geteilt, kein fest hinterlegter
  Text im Code.

## Architektur

**Neues Paket:** `share_plus` (Standardlösung für den nativen
Betriebssystem-Teilen-Dialog; funktioniert automatisch mit jeder installierten App,
die Dateien empfangen kann — kein appspezifischer Code für WhatsApp o.ä. nötig).

**Kein Umweg über eine temporäre Datei:** `share_plus`s `XFile` (aus dem
`cross_file`-Paket) kann direkt aus einem `Uint8List` gebaut werden
(`XFile.fromData(bytes, name: ..., mimeType: ...)`), ohne die Bytes vorher auf die
Festplatte schreiben zu müssen — passt zur bestehenden Praxis im Projekt, Audiodaten
nur im Speicher zu halten (z.B. `PlaybackButton` nutzt genauso `BytesSource` statt
einer Temp-Datei).

**Kleine Ergänzung an `SessionState`:** Aktuell speichert `SessionState` nur die rohen
Bytes der Gesangsaufnahme (`sungAudioBytes`), nicht deren Dateiname/Format. Eigene
Mikrofonaufnahmen sind laut `RecordingControl` immer `.m4a` (AAC), aber über "Datei
wählen" könnte auch ein anderes Format (z.B. `.wav`) hochgeladen werden — ohne den
richtigen Dateinamen/die richtige Endung beim Teilen könnte die empfangende App die
Datei nicht korrekt öffnen. Deshalb bekommt `SessionState` ein neues Feld
`sungAudioFilename` (`String?`), das `analyzeAudio(Uint8List bytes, String filename)`
zusätzlich zu den Bytes speichert (der Parameter `filename` existiert dort bereits,
wird bisher aber nur an die API weitergereicht, nicht im State gehalten).

## UI

Neues, eigenständiges Widget `ShareButton` (`mobile/lib/widgets/share_button.dart`),
analog zu `PlaybackButton`: eine klare Aufgabe (Teilen-Dialog öffnen), rendert nichts,
solange keine Aufnahme vorliegt. Wird in `home_screen.dart` direkt neben dem
bestehenden `PlaybackButton` in Abschnitt "2. Gesangsaufnahme" platziert (derselbe
`Row`, dieselbe `ConstrainedBox`-Breite wie der bestehende Button).

## Fehlerbehandlung

Folgt dem bestehenden `PlaybackButton`-Muster: ein synchroner `_isBusy`-Guard
verhindert Doppel-Taps während der Teilen-Dialog geöffnet wird, eine kurze
Fehlermeldung (`Text` in Rot, wie bei `PlaybackButton`s `_errorMessage`) erscheint,
falls `Share.shareXFiles(...)` aus irgendeinem Grund eine Exception wirft.

## Tests

Widget-Test `mobile/test/share_button_test.dart`, analog zu
`playback_button_test.dart`: `share_plus`s eigentlicher Aufruf wird über eine
injizierbare Abstraktion (wie `AudioPlaybackController` bei `PlaybackButton`)
fake-bar gemacht, damit kein echter Plattform-Kanal in `flutter_test` nötig ist —
prüft, dass ein Tap den Share-Aufruf mit den richtigen Bytes/Dateinamen auslöst, dass
der Button ohne Aufnahme nichts rendert, und dass eine fehlschlagende Share-Aktion die
Fehlermeldung anzeigt statt abzustürzen.

## Out of Scope (bewusst nicht Teil dieses Designs)

- Kein Teilen-Button für die Referenzaufnahme.
- Kein Begleittext/keine Bildunterschrift beim Teilen.
- Keine app-spezifische Integration (z.B. direktes Teilen zu WhatsApp ohne
  System-Dialog) — der native Teilen-Dialog deckt das bereits ab.

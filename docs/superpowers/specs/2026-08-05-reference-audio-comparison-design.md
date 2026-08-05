# Eigene Referenzaufnahme statt MIDI (Mobile-App)

Status: Design abgestimmt am 2026-08-05, bereit für Implementierungsplan.

## Kontext

Bisher (Phase 1) muss der Nutzer eine MIDI-Datei mit der Zielmelodie hochladen, um seine
Gesangsaufnahme dagegen zu vergleichen. Für beliebige Songs ist eine passende MIDI-Datei oft
schwer zu finden. Ein automatischer YouTube-Download als Alternative wurde verworfen, da er der
dokumentierten Leitplanke "kein automatischer Download geschützter Musik" (`PLAN.md`)
widerspricht und gegen YouTubes Nutzungsbedingungen verstößt.

Stattdessen: Der Nutzer stellt selbst eine Referenzaufnahme bereit (eigene Datei oder eigene
Mikrofon-Aufnahme, z. B. der Originalsong aus einer legalen Quelle oder eine eigene
Referenzeinsingung). Diese Aufnahme wird serverseitig genauso per pYIN analysiert wie die
eigentliche Gesangsaufnahme — es gibt also technisch keinen Unterschied zwischen "Referenz" und
"Versuch", nur die Interpretation im Client unterscheidet sich.

**Scope-Entscheidungen (mit Nutzer geklärt):**
- Alternative *neben* MIDI, nicht als Ersatz — beide Wege bleiben nutzbar.
- Referenz kann sowohl per Datei-Upload als auch per Live-Mikrofonaufnahme bereitgestellt werden.
- Nur die Mobile-App (Flutter, `mobile/`) wird angepasst; das Web-Frontend (`frontend/app.js`)
  bleibt vorerst unverändert bei MIDI-only.
- Transpose (±12 Halbtöne) funktioniert auch für die Referenzaufnahme, rein rechnerisch im
  Client, ohne erneuten Server-Roundtrip.

## Architektur & Datenfluss

**Keine Backend-Änderung.** Der bestehende Endpunkt `POST /api/audio/analyze`
(`backend/api/routes.py`) liefert für jede Audiodatei eine pYIN-Kurve
(`{"t": float, "hz": float|null, "voiced": bool, "confidence": float}` pro Zeitschritt) — das
reicht für Referenz- und Versuchs-Aufnahme gleichermaßen.

Beobachtung aus dem bestehenden Code: `TargetPoint` (MIDI-Zielkurve: `t`/`hz`/`midiNote`) und
`SungPoint` (Audio-Kurve: `t`/`hz`/`voiced`/`confidence`) haben beide bereits `t`/`hz` (`hz ==
null` bedeutet "keine Tonhöhe an dieser Stelle" in beiden Fällen). `PitchChart`
(`mobile/lib/widgets/pitch_chart.dart`) nutzt von `TargetPoint` ausschließlich `t` und `hz` zum
Zeichnen der Zielkurve — `midiNote` wird dort nicht verwendet. Deshalb wird eine analysierte
Referenzaufnahme nach der Analyse in eine `TargetPoint`-Liste umgewandelt (`midiNote: null`, `hz`
ggf. transponiert) und in genau den Chart-Slot gegeben, der heute die MIDI-Kurve bekommt.
`PitchChart` selbst wird nicht verändert.

Datenfluss im Referenz-Modus:
```
Referenzdatei/-aufnahme
  → AudioApi.analyzeAudio()            [bestehend, unverändert]
  → List<SungPoint>                    (roh, unverschoben, gecacht in SessionState)
  → bei jeder Transpose-Änderung rein lokal: hz × 2^(semitone/12)
  → als List<TargetPoint> (midiNote: null) in denselben Chart-Slot wie die MIDI-Kurve
```

## State-Änderungen (`mobile/lib/state/session_state.dart`)

- Neues `enum ReferenceSource { midi, recording }`; Feld `referenceSource` (Default `midi`).
- Neue Felder, additiv neben den bestehenden `midi*`-Feldern (kein Umbenennen bestehender
  Felder, kleinerer Diff): `List<SungPoint> referenceRawCurve = []`, `LoadStatus
  referenceStatus = LoadStatus.idle`, `String referenceMessage = ''`.
- Neue Methode `analyzeReference(Uint8List bytes, String filename)`: ruft `audioApi.analyzeAudio`
  auf (identisch zu `analyzeAudio`), speichert das Ergebnis aber in `referenceRawCurve` statt in
  `sungCurve`, mit denselben Lade-/Fehlerzuständen wie beim bestehenden `analyzeAudio`.
- Neue Methode `setReferenceSource(ReferenceSource source)`: setzt `referenceSource`, setzt den
  Gesangs-Take-Abschnitt zurück (neuer Durchlauf: `sungCurve = []`, `audioStatus =
  LoadStatus.idle`, `audioMessage = ''`), behält aber MIDI- *und* Referenz-Daten unabhängig
  gecacht (Hin- und Herschalten verwirft nichts Bereits-Geladenes).
- `setTranspose` verzweigt nach `referenceSource`:
  - `midi`: unverändertes Verhalten (Server-Reload über `_reloadTargetCurve`).
  - `recording`: nur `transposeSemitones` setzen + `notifyListeners()`, kein Netzwerk-Call (die
    Verschiebung passiert lazy im Getter unten).
- Neuer Getter `List<TargetPoint> get displayedTargetCurve`:
  - `midi`-Modus: gibt `targetCurve` unverändert zurück.
  - `recording`-Modus: mappt `referenceRawCurve` auf `TargetPoint(t: p.t, hz: shifted, midiNote:
    null)`, wobei `shifted = p.hz == null ? null : p.hz! * pow(2, transposeSemitones / 12)`
    (`dart:math`).
- `audioSectionEnabled` erweitert: `midi`-Modus wie bisher (`selectedTrackIndex != null`),
  `recording`-Modus: `referenceRawCurve.isNotEmpty`.

## UI-Änderungen (`mobile/lib/screens/home_screen.dart`)

- Neuer Umschalter oben in Abschnitt 1 (`SegmentedButton<ReferenceSource>`, zwei Optionen:
  "MIDI-Datei" / "Eigene Aufnahme"), ruft `session.setReferenceSource(...)`.
- Abschnitt 1 zeigt je nach `session.referenceSource`:
  - `midi`: bestehender MIDI-Picker-Button + `TrackCandidateCard`-Liste (unverändert).
  - `recording`: eine zweite, unveränderte `RecordingControl`-Instanz mit `onAudioReady:
    session.analyzeReference`, plus eigener `StatusBanner(status: session.referenceStatus,
    message: session.referenceMessage)`.
- `TransposeControl`-Sichtbarkeit wird von `selectedTrackIndex != null` auf
  `session.audioSectionEnabled` generalisiert (deckt beide Modi ab).
- Abschnitt 3 (Chart) verwendet `session.displayedTargetCurve` statt `session.targetCurve`.
- Überschrift "1. MIDI-Referenzspur" wird zu "1. Zielmelodie" (gilt jetzt für beide Modi).

## Fehlerbehandlung

Folgt 1:1 dem bestehenden Muster (`LoadStatus.error` + deutsche Fehlermeldung aus
`ApiException`/`_messageOf`) — kein neuer Fehlerpfad nötig, da derselbe Endpunkt/dieselbe
Fehlerbehandlung wie bei der bestehenden Gesangsaufnahme greift (`analyze_pitch` liefert bei
nicht dekodierbarem Audio bereits `PitchAnalysisError` → HTTP 400 → `ApiException`).

## Tests

- Erweiterung von `mobile/test/` um einen State-Test (kein Widget-Pump nötig): `setReferenceSource
  (ReferenceSource.recording)` aufrufen, eine gemockte/gestubte `referenceRawCurve` setzen (oder
  über einen gefakten `AudioApi` via `analyzeReference`), `setTranspose` aufrufen und prüfen, dass
  `displayedTargetCurve` die transponierte Referenzkurve liefert (nicht die leere MIDI-Kurve).
- Optionaler Widget-Smoke-Test: im Referenz-Modus ersetzt der Umschalter den MIDI-Picker-Button
  durch die zweite `RecordingControl`-Instanz.

## Out of Scope (bewusst nicht Teil dieses Designs)

- Web-Frontend (`frontend/app.js`) bleibt MIDI-only.
- Kein Backend-Endpunkt-Änderung, kein größeres Zeitlimit für Referenzclips (Ansatz B/C aus der
  Diskussion wurden verworfen, YAGNI).
- Kein serverseitiges Cachen/Session-Handling für Referenzkurven — der Client hält die rohe Kurve
  lokal im `SessionState`.

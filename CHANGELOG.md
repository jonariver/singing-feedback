# Changelog

Diese Datei beschreibt in natürlicher Sprache, was mit jedem Commit passiert ist — als
Ergänzung zu `git log`, nicht als Ersatz. Neueste Änderungen oben.

## 2026-08-02 — Projektstart

- **`e1532f6` — Phase 0+1: Backend-Skeleton und vertikaler Prototyp**
  Der allererste Commit. Legt das komplette Python/FastAPI-Backend an: MIDI-Parsing und
  Track-Kandidaten-Erkennung, pYIN-basierte Tonhöhenerkennung der Gesangsaufnahme, die
  In-Memory-Session-Verwaltung für hochgeladene MIDI-Dateien, sowie ein schlankes
  Vanilla-JS/Canvas-Frontend (`frontend/`), das beide Kurven übereinandergelegt anzeigt.
  Bewusst ohne Datenbank, ohne Nutzerkonten, ohne dauerhafte Speicherung von Audiodateien.

## 2026-08-05 — Backend für Hosting/Mobile vorbereiten

- **`0050560` — Prepare backend for hosted/mobile use: CORS, rate limiting, upload hardening**
  Bisher lief das Backend nur lokal (`127.0.0.1`, für einen einzigen Nutzer gedacht). Dieser
  Commit macht es fit dafür, auch von einer externen Mobile-App aus angesprochen zu werden:
  optionales CORS-Middleware, ein einfaches IP-basiertes Rate-Limiting für die
  Upload-Endpunkte, ein Content-Length-Vorab-Check gegen offensichtlich zu große Uploads, und
  ein PyAV-Fallback in der Tonhöhenerkennung für Audioformate (AAC/M4A, wie sie
  Mobile-Recorder produzieren), die die bisherige Bibliothek ohne System-ffmpeg nicht lesen
  konnte.

- **`7175894` — Add Flutter mobile client (Phase 1 parity) and mobile port notes**
  Der native Mobile-Client (Android/iOS) entsteht: MIDI-Upload, Track-Auswahl,
  Mikrofonaufnahme (oder Datei-Upload) und Tonhöhenkurven-Vergleich — als 1:1-Portierung des
  Web-Frontends auf Flutter, plus Mikrofonaufnahme und ein Transpose-Regler als bewusste
  Ergänzungen. `docs/mobile-port-notes.md` hält die Architektur-Entscheidung fest (Backend
  bleibt wie es ist, gehostet statt nur lokal; nur der Client wird neu gebaut), inklusive der
  verworfenen Alternativen (WebView, Python direkt auf dem Gerät, komplette native
  Neuimplementierung der DSP-Logik).

## 2026-08-05 — Feature: Referenzaufnahme statt MIDI

Der Nutzer wollte statt einer MIDI-Datei auch eine eigene Aufnahme (oder einen YouTube-Link,
der aber aus rechtlichen Gründen verworfen wurde) als Vergleichsziel angeben können.

- **`ffbe994` — Design-Spec** und **`0838561` — Implementierungsplan** für das Feature.
- **`a2e7933` — feat: add reference-audio mode to SessionState**
  Der Flutter-App-State bekommt einen zweiten Modus: Referenzaufnahme statt MIDI-Datei. Die
  hochgeladene Referenz durchläuft denselben Tonhöhenerkennungs-Endpunkt wie die
  Gesangsaufnahme; Transponieren passiert rein rechnerisch im Client, ohne erneuten
  Server-Aufruf.
- **`80f1ddd` — feat: add reference-audio toggle to home screen**
  Der Umschalter "MIDI-Datei" / "Eigene Aufnahme" erscheint in der App-Oberfläche.
- **`96863a1` — fix: resolve final-review findings**
  Das abschließende Review fand zwei echte Bugs: einen überflüssigen Import, der die
  statische Analyse rot färbte, und einen "Transpose-Leck" — ein Halbtonwert, der beim
  Umschalten zwischen MIDI- und Referenz-Modus fälschlich übernommen wurde und Regler/Kurve
  auseinanderlaufen ließ. Beide behoben.
- **`b87f795` — Ignore local .worktrees/ directory**
  Housekeeping: Git-Worktrees (für die isolierte Feature-Entwicklung) werden ab jetzt
  konsequent genutzt und ausgeschlossen.

## 2026-08-05 — Feature: Aufnahme abhören & löschen vor dem Hochladen

Vorher wurde eine Aufnahme sofort nach dem Stoppen hochgeladen — ohne Möglichkeit, sie sich
vorher nochmal anzuhören oder zu verwerfen.

- **`f72ae68` — Design-Spec** und **`7a5e6fb` — Implementierungsplan**.
- **`8d9bfdc` — feat: add listen-back/discard preview before uploading a recording**
  Nach Aufnahme-Stopp oder Dateiauswahl erscheint jetzt eine Vorschau mit
  Play/Pause-, Löschen- und "Verwenden"-Buttons; erst "Verwenden" löst den Upload aus.
- **`04ee18e`, `fdf8671`, `15d41c1` — drei Fix-Runden** für Race-Conditions, die beim
  gleichzeitigen Antippen mehrerer Buttons (Play/Löschen/Verwenden) während einer laufenden
  Wiedergabe auftreten konnten: eine bereits laufende Bestätigung ließ sich nicht mehr
  sauber abbrechen, ein Fehler beim Stoppen der Wiedergabe konnte die Buttons dauerhaft
  sperren, und der Play/Pause-Button selbst hing anfangs nicht am selben Schutzmechanismus
  wie Löschen/Verwenden. Alle drei durch ein gemeinsames `_isBusy`-Sperr-Muster gelöst.

## 2026-08-05 — Kleine Anpassung: Umschalter-Reihenfolge

- **`9ccc672` — Show "Eigene Aufnahme" before "MIDI-Datei"**
  Auf Nutzerwunsch steht "Eigene Aufnahme" jetzt zuerst im Umschalter.

## 2026-08-05 — Feature: Dark/Teal-Redesign nach Figma-Vorlage

Der Nutzer teilte eine Figma-Referenz (eine Musik-App-UI) und wollte deren visuellen Stil
übernehmen — bewusst nur Farben/Typografie/Formen, nicht die dortige
Bibliotheks-/Playlist-Funktion.

- **`bdba82d` — Design-Spec** und **`d5f4fd9` — Implementierungsplan**.
- **`ac6a4a6` — feat: apply dark/teal theme base from Figma reference**
  Ein komplettes dunkles `ThemeData`: near-black Hintergrund, Teal-Akzentfarben, die
  Google-Font "Jost" als freier Ersatz für die lizenzierte Figma-Schrift "Century Gothic",
  durchgehend abgerundete Pill-Buttons.
- **`3b31dfc` — feat: adapt hardcoded widget colors to the dark/teal theme**
  Vier Stellen mit fest verdrahteten, auf helles Theme abgestimmten Farben angepasst: die
  Zielkurve im Chart (jetzt Teal statt Blau), die Auswahl-Farbe der Track-Karten, die
  Status-Meldungsfarben, und ein neuer gefüllter Kreis-Button fürs Abspielen in der
  Aufnahme-Vorschau.
- **`b46a1ce` — fix: make native splash screen dark**
  Das abschließende Review fand, dass der native Android/iOS-Splashscreen noch hell war und
  beim App-Start kurz aufgeblitzt wäre — behoben, plus ein veralteter Code-Kommentar
  korrigiert.

Zur Verifikation dieses Features wurde eigens ein headless Android-Emulator in der
Entwicklungsumgebung eingerichtet, damit Screenshots direkt mit der Figma-Vorlage
abgeglichen werden konnten, statt sich auf Beschreibungen zu verlassen.

## 2026-08-05 — Feature: Aufnahme nach dem Hochladen anhören

Auch nach dem Hochladen sollte man sich die eigene Aufnahme nochmal anhören können.

- **`8fc35ac` — Design-Spec** und **`f9917de` — Implementierungsplan**.
- **`c5c4861` — feat: persist confirmed recording bytes in SessionState**
  Die rohen Audio-Bytes werden nach dem Hochladen nicht mehr verworfen, sondern im
  App-State gehalten — und zwar so, dass sie einen Wechsel zwischen MIDI- und
  Referenz-Modus überleben (der die Aufnahme-Widgets sonst zerstören würde).
- **`96a75f9` — feat: add playback-after-upload button**
  Ein neuer Play-Button erscheint neben der Erfolgsmeldung, sowohl bei der Referenz- als
  auch bei der Gesangsaufnahme.
- **`3a78bde`, `3acfdad` — zwei Fix-Runden**
  Ein möglicher Absturz, wenn eine Fehlermeldung im falschen Moment auftauchte, sowie ein
  Layout-Fehler, bei dem eine lange Fehlermeldung den Bildschirm gesprengt hätte.
- **`83bc90f` — Fix PlaybackButton setState-after-dispose and layout regression; add tests**
  Das abschließende Review fand zwei weitere echte Bugs (ein `setState`-Aufruf auf einem
  bereits zerstörten Widget, und eine Nebenwirkung des vorherigen Layout-Fixes, die der
  Statusmeldung dauerhaft die Hälfte des verfügbaren Platzes wegnahm) sowie Anlass, entgegen
  der ursprünglichen Planung doch automatisierte Tests für den neuen Button zu schreiben —
  beides umgesetzt, inklusive eines eigens dafür geschaffenen Test-Einstiegspunkts, um den
  `AudioPlayer` in Tests durch eine Fälschung zu ersetzen.

## 2026-08-06 — Feature: DTW-Zeitausrichtung (Phase 3)

Bisher lagen Ziel- und Gesangskurve einfach unausgerichtet nebeneinander im Chart — wer zu
früh oder zu spät einsetzte, sah eine verschobene statt eine vergleichbare Kurve. Phase 3
richtet die gesungene Aufnahme per DTW zeitlich an der Zielmelodie aus, sowohl bei
MIDI-Zielen als auch bei einer selbst aufgenommenen Referenz.

- **`a4a07d9` — Design-Spec** und **`c32e91d` — Implementierungsplan**.
- **`77e2a4e` — refactor: extract audio decoding into backend/audio_io.py**
  Vorarbeit: die bisher in `pitch_detection` verstreute Audio-Dekodierung (WAV/MP3/WebM via
  PyAV-Fallback) wandert in ein eigenes Modul, damit sowohl die Pitch-Erkennung als auch der
  neue Sync-Endpunkt dieselbe Dekodier-/Kürzungslogik (inkl. `MAX_AUDIO_SECONDS`) benutzen
  können, ohne sie zu duplizieren.
- **`8bcc9c2` — feat: add onset-envelope extraction for DTW alignment**
  Neues Modul `backend/sync/features.py`: statt DTW auf der Rohtonhöhe laufen zu lassen (was
  genau dann versagen würde, wenn jemand die falsche Note singt), wird eine
  tonhöhen-unabhängige Onset-/Energie-Hüllkurve extrahiert — synthetisch aus den
  MIDI-Notenanfängen für die Zielseite, aus `librosa.onset.onset_strength` für echtes Audio.
- **`2a1038d` — fix: use consistent floor semantics for onset_frame**
  Ein Rundungsfehler hätte Onsets nah am Spurende still verworfen, wenn `onset_frame` anders
  gerundet wurde als die Frame-Anzahl der Kurve; mit Regressionstest behoben.
- **`cf1fe8e` — feat: add DTW curve alignment (backend/sync/align.py)**
  Das Herzstück: `align_curves()` normalisiert beide Hüllkurven (Z-Score) und lässt
  `librosa.sequence.dtw` (globales Alignment, `subseq=False`) einen Warping-Pfad berechnen,
  aus dem jeder gesungene Frame ein `aligned_t` auf der Zielzeitachse bekommt.
- **`4fda8b5` — test: add Phase 3 end-to-end DTW alignment validation**
  End-to-End-Test mit synthetischen Fixtures und absichtlichem Timing-Versatz, analog zum
  Phase-1-E2E-Test.
- **`d5ff227` — feat: add POST /api/sync/align endpoint** und **`6fcefdd` — fix: use
  2 * MAX_AUDIO_UPLOAD_BYTES for early content-length check**
  Neuer Endpunkt, der Gesangs- und Zielkurve (MIDI-Session oder Referenzaudio) entgegennimmt
  und das Alignment-Ergebnis zurückgibt; der Fix korrigiert die Vorab-Größenprüfung, die bei
  zwei Uploads (Gesang + Referenz) sonst zu früh ausgelöst hätte.
- **`c416fc8` — feat: add SyncApi and aligned_t support to mobile API layer**
  Dünner Client-Wrapper für den neuen Endpunkt plus `alignedT`-Feld im `SungPoint`-Modell.
- **`60ceeb0` — feat: auto-trigger DTW alignment after recording analysis**
  `SessionState.align()` läuft automatisch am Ende von `analyzeAudio()` — kein zusätzlicher
  manueller Button nötig.
- **`5e2ad6a` — feat: render DTW-aligned sung curve in PitchChart**
  Der Chart zeichnet jetzt die ausgerichtete Kurve, sobald ein Alignment vorliegt, und fällt
  bei fehlendem/fehlgeschlagenem Alignment automatisch auf die rohe Kurve zurück statt
  abzustürzen oder leer zu bleiben.

**Abschließendes Review (ohne eigenen Commit-Hash, in diesem Fix-Sweep behoben):** vier
wichtige Befunde — ein wechselndes Ziel (andere MIDI-Spur oder neue Referenzaufnahme) ließ
das alte Alignment stehen und zeichnete es gegen die falsche Zielmelodie weiter; ein langes
MIDI-Ziel war serverseitig nicht in der Dauer begrenzt und konnte die DTW-Kostenmatrix auf
mehrere GB RAM aufblähen bzw. (bei global erzwungenem Alignment) ein unbemerkt falsches,
verschmiertes Ergebnis liefern, wenn die Aufnahme nur einen Bruchteil des Ziels abdeckte; und
der Ausrichtungsstatus wurde zwar berechnet, aber nirgends angezeigt. Behoben durch: Reset des
Alignment-Zustands in `selectTrack()`/`analyzeReference()`, einen neuen
Dauer-Verhältnis-Schutz (`duration_ratio_exceeds_limit`, Ziel darf höchstens dreimal so lang
sein wie die Aufnahme) vor dem DTW-Aufruf in `sync_align`, und eine `StatusBanner` für
`alignStatus`/`alignMessage` im Home-Screen.

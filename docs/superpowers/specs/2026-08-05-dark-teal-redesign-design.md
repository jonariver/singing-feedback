# Visueller Stil aus Figma-Referenz auf die Mobile-App übertragen

Status: Design abgestimmt am 2026-08-05, bereit für Implementierungsplan.

## Kontext

Der Nutzer hat eine Figma-Referenz geteilt (Musium – Music App UI, Community-File,
"Folders"/"Your Library"-Screen, node `182:980`) und möchte deren visuellen Stil auf den
Flutter-Mobile-Prototyp übertragen — **nicht** die konkrete Bibliotheks-/Playlist-Funktion
dieses Screens (die hat mit der Singing-Feedback-App nichts zu tun), sondern Farbpalette,
Typografie und Formsprache, angewendet auf die bestehenden drei Abschnitte (Zielmelodie
wählen, Aufnehmen, Tonhöhenvergleich).

Aus dem Figma-Screen extrahierte Tokens:
- Hintergrund: `#121111` (near-black)
- Akzent: `#00C2CB` (Teal, Primärfarbe), `#39C0D4` (helleres Teal, Sekundärtext/-akzent)
- Gedämpfter Text: `#8A9A9D`
- Schrift: Century Gothic Bold (nicht lizenzfrei verfügbar → Ersatz nötig, siehe unten)
- Formsprache: durchgehend abgerundete "Pill"-Buttons (`border-radius: 23px` auf 28px hohen
  Filtern), kreisrunde Icon-Buttons (56px, gefüllter Teal-Kreis)

**Scope-Entscheidungen (mit Nutzer geklärt):**
- Nur der visuelle Stil, keine neue Navigationsstruktur/Bibliotheksfunktion.
- Century Gothic wird durch die freie Google Font **Jost** ersetzt (ähnlicher geometrischer
  Charakter, keine Lizenzfrage, kein Font-Bundling nötig) statt die echte Schrift zu bundlen
  oder ganz auf die Standardschrift zu verzichten.
- Die Zielkurve im Pitch-Chart wechselt von Blau auf Teal (passt zur neuen Akzentfarbe); die
  Gesangskurve bleibt Orange (guter Kontrast als Komplementärfarbe zu Teal).
- Ansatz A gegenüber zwei Alternativen bevorzugt: nur globales `ThemeData` ändern und die
  hartcodierten Farben unangetastet lassen (optisch kaputt, da diese Farben auf helles Theme
  abgestimmt sind) oder ein separates `lib/theme/app_theme.dart`-Tokenmodul einführen
  (mehr Aufwand als für diesen Umfang gerechtfertigt, widerspricht dem bisher bewusst
  schlanken Projektstil).

## Theme-Basis (`mobile/lib/main.dart`)

```dart
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
```

Neue Abhängigkeit: `google_fonts` (Standard-Package, lädt/bundlet "Jost").

## Betroffene Einzel-Widgets

Diese Dateien haben fest verdrahtete, auf helles Theme abgestimmte Farben, die ein globales
`ThemeData` allein nicht erreicht:

- **`mobile/lib/widgets/pitch_chart.dart`**: `_targetColor` wird `Color(0xFF00C2CB)` (Teal).
  `_sungColor` bleibt `Color(0xFFEA580C)` (Orange). `_gridColor`/`_labelColor` unverändert
  (funktionieren als Mitteltöne auf hell und dunkel gleichermaßen).
- **`mobile/lib/widgets/track_candidate_card.dart`**: `Colors.blue.shade50`
  (Auswahl-Hintergrund) wird `Theme.of(context).colorScheme.primary.withOpacity(0.15)`.
  `Colors.orange.shade800` (Warnungstext) wird `Colors.orange.shade300` (heller, lesbar auf
  dunklem Grund).
- **`mobile/lib/widgets/status_banner.dart`**: `Colors.red/green/grey.shade700` (zu dunkel für
  dunklen Hintergrund) werden auf `.shade300`/`.shade400` aufgehellt.
- **`mobile/lib/widgets/recording_control.dart`**: Play/Pause- und Aufnehmen-Buttons (primäre
  Aktionen) wechseln von normalem `IconButton` auf `IconButton.filled` (Material-3-Variante mit
  gefülltem Kreis-Hintergrund in Akzentfarbe) — entspricht den runden Teal-Icon-Buttons im
  Figma-Design. Löschen bleibt bewusst ein normaler (nicht gefüllter) Icon-Button, um die
  destruktive Aktion visuell nicht gleich zu betonen.

`mobile/lib/screens/home_screen.dart` und `mobile/lib/widgets/transpose_control.dart` brauchen
keine Änderung — keine hartcodierten Farben, übernehmen das neue Theme automatisch.

## Tests

Keine neuen automatisierten Tests — reine Farb-/Typografie-/Form-Änderungen sind ohne
Golden-Image-Tests (neue, hier nicht gerechtfertigte Test-Infrastruktur) nicht sinnvoll
automatisiert prüfbar. Die bestehende Suite (8/8) prüft nur Text-Inhalte
(`find.text(...)`), keine Farben — bleibt als Regressionsabsicherung unverändert grün.

## Verifikation

`flutter analyze` sauber, bestehende Suite bleibt grün, danach visuelle Prüfung per
Android-Emulator (headless, KVM-beschleunigt, in dieser WSL2-Umgebung neu eingerichtet):
App bauen, Screenshots aller drei Screen-Abschnitte machen, mit der Figma-Referenz
vergleichen — Assistent prüft das selbst anhand der Screenshots, statt auf eine
Beschreibung durch den Nutzer angewiesen zu sein.

## Out of Scope (bewusst nicht Teil dieses Designs)

- Keine neue Navigationsstruktur oder Bibliotheks-/Playlist-Funktion aus dem Figma-File.
- Keine Golden-Image-Test-Infrastruktur.
- `frontend/app.js` (Web-Frontend) bleibt unverändert.

# Design: Einklappbare Abschnitte auf dem Home-Screen

**Datum:** 2026-08-08
**Status:** Genehmigt, bereit für Plan

## Kontext

`home_screen.dart` zeigt fünf nummerierte Abschnitte (`1. Zielmelodie`, `2.
Gesangsaufnahme`, `3. Tonhöhen-Vergleich`, `4. Bewertung`, `5. Feedback`) untereinander
in einer festen, immer vollständig sichtbaren `ListView`. Mit wachsender Anzahl an
Bedienelementen pro Abschnitt (Toleranz-Preset, Feedback-Provider, Seekbars, etc.) wird
der Screen zunehmend lang und unübersichtlich, besonders wenn man sich nur für einen
späteren Abschnitt interessiert. Ziel: jeder Abschnitt lässt sich einzeln ein-/ausklappen.

Erste Teilaufgabe von drei größeren, unabhängig voneinander gewünschten Features
(einklappbare Abschnitte, Aufnahmen speichern, Crossfade-Regler) — bewusst als
eigenständiges, kleinstes und unabhängigstes der drei zuerst umgesetzt.

## Architektur

Jeder der fünf Abschnitte wird von einem Flutter-`ExpansionTile` umschlossen. Der
bisherige `Text('N. Titel', style: Theme.of(context).textTheme.titleMedium)`-Header wird
zum `title:` des Tiles; der komplette restliche Inhalt des Abschnitts (unverändert,
inklusive aller bestehenden bedingten Verzweigungen wie MIDI- vs.
Referenzaufnahme-Modus in Abschnitt 1) wandert in `children: [...]`.

```dart
ExpansionTile(
  title: Text('1. Zielmelodie', style: Theme.of(context).textTheme.titleMedium),
  initiallyExpanded: true,
  children: [
    // bisheriger Inhalt von Abschnitt 1, unveraendert
  ],
),
```

`initiallyExpanded: true` für alle fünf Tiles — bewusst gewählt, damit die App beim
ersten Öffnen wie bisher komplett aufgeklappt startet. **Kein neuer State in
`SessionState`, keine Persistenz** — Flutter verwaltet den Auf-/Zu-Zustand jedes
`ExpansionTile` intern und rein lokal; ein App-Neustart klappt alles wieder auf. Tippen
auf den Header (Titeltext oder Pfeil-Icon) klappt den jeweiligen Abschnitt ein/aus, wie
vom Widget bereits eingebaut.

Die bestehenden `const Divider(height: 32)` zwischen den Abschnitten bleiben zur
optischen Trennung zwischen den fünf `ExpansionTile`s erhalten (also außerhalb der
Tiles, nicht als `children`-Eintrag).

Diese Änderung ist eine rein strukturelle Restrukturierung von `home_screen.dart` — kein
Backend-Bezug, keine Änderung an `SessionState` oder irgendeiner anderen Datei.

## Testing

- Kein neuer `SessionState`-Test nötig, da kein neuer State entsteht.
- Ein neuer, einfacher Widget-Smoke-Test (`mobile/test/home_screen_test.dart`, bislang
  nicht vorhanden) pumpt `HomeScreen` in einen `ChangeNotifierProvider` mit einer
  minimalen `SessionState` und prüft: alle fünf Abschnitts-Titel sind initial sichtbar
  (`find.text('1. Zielmelodie')` etc.); nach `tester.tap()` auf einen Titel und
  `tester.pumpAndSettle()` (für die Auf-/Zuklapp-Animation) ist ein für diesen Abschnitt
  charakteristisches Kind-Widget nicht mehr im Baum (z. B. der "MIDI-Datei wählen"-Button
  aus Abschnitt 1).

## Out of Scope (bewusst nicht Teil dieser Spec)

- Automatisches Ein-/Ausklappen abhängig vom Fortschritt (mit dem Nutzer während des
  Brainstormings verworfen zugunsten von rein manuellem Verhalten).
- Persistenz des Auf-/Zu-Zustands über einen App-Neustart hinweg (ebenfalls bewusst
  verworfen — jede neue Aufnahme-Session soll mit allem sichtbar starten).
- Die beiden anderen im selben Nutzer-Wunsch genannten Features (Aufnahmen speichern,
  Crossfade-Regler) — eigene, separate Spec/Plan-Runden.

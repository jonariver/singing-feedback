# Design: Toleranz-Preset für die Cents-Bewertung

**Datum:** 2026-08-07
**Status:** Genehmigt, bereit für Plan

## Kontext

Nutzer-Feedback: Die aktuelle, feste Klassifikation von Tonhöhen-Abweichungen
(`backend/config.py`: `CENTS_GREEN_THRESHOLD=15.0`, `CENTS_YELLOW_THRESHOLD=50.0` —
alles darüber rot) wirkt in der Noten-Liste am Ende der Auswertung
(`score_summary_view.dart`) oft "zu krass": viele Noten werden gelb/rot markiert,
obwohl sie sich beim Anhören richtig angehört haben. 15 Cent ist eine sehr enge,
professionelle Genauigkeitsanforderung; 50 Cent ist ein Viertelton.

Ziel dieser Spec: ein einstellbares Toleranz-Preset (Streng/Normal/Locker), das
nur die grün/gelb/rot-Klassifikation der Tonhöhen-Abweichung beeinflusst — nicht
Timing, Stabilität, Drift, Glide-Erkennung oder verfehlte Noten (bewusste
Scope-Entscheidung: diese Kriterien bleiben unverändert streng, siehe "Out of
Scope"). Zusätzlich wird der bisherige Default (15/50 Cent) selbst als zu streng
empfunden — die gesamte Skala rutscht eine Stufe nach oben, sodass "Normal" nach
dieser Änderung dem bisherigen (nie ausgelieferten) "Locker"-Vorschlag entspricht.

## Architektur

### 1. Preset-Tabelle (`backend/config.py`)

Die zwei festen Konstanten werden durch eine Preset-Tabelle ersetzt:

```python
# Bewertungs-Engine: Cent-Abweichung & verfehlte Zielnoten. Toleranz-Presets
# fuer die gruen/gelb/rot-Klassifikation (siehe
# docs/superpowers/specs/2026-08-07-tolerance-preset-design.md); "normal" ist
# server- und app-seitiger Default.
CENTS_TOLERANCE_PRESETS = {
    "strict": {"green": 15.0, "yellow": 50.0},
    "normal": {"green": 25.0, "yellow": 75.0},
    "loose": {"green": 35.0, "yellow": 100.0},
}
DEFAULT_CENTS_TOLERANCE_PRESET = "normal"
```

`MISSED_NOTE_CENTS_THRESHOLD = 300.0` bleibt unverändert und unabhängig vom
Preset (siehe "Out of Scope").

### 2. Backend-Scoring (`backend/scoring/pitch.py`, `backend/scoring/glides.py`, `backend/scoring/score.py`)

- `pitch.py::classify_cents(value, green_threshold, yellow_threshold)` — die
  beiden Schwellen werden zu Pflichtparametern (keine Default-Werte, damit ein
  vergessener Parameter nicht unbemerkt auf falsche Werte zurückfällt; alle
  Aufrufer in dieser Codebasis sind bekannt und werden mit dieser Änderung
  angepasst).
- `pitch.py::compute_cents_deviation(note, attributed_frames, green_threshold, yellow_threshold)`
  — reicht beide Werte an `classify_cents()` durch.
- `glides.py::compute_glide(note, attributed_frames, green_threshold)` — nutzt
  denselben Grün-Schwellwert wie die Cents-Klassifikation, um zu prüfen, ob der
  Rest der Note nach dem Reingleiten sauber getroffen wurde (gleiches Konzept,
  gleicher Wert, kein zweiter unabhängiger Parameter).
- `score.py::score_performance(target_curve, sung_curve, frame_rate_hz=100.0, tolerance_preset="normal")`
  — neuer Parameter. Schlägt `CENTS_TOLERANCE_PRESETS[tolerance_preset]` nach;
  ein unbekannter Key löst `KeyError` aus (durch die bestehende
  `except (ValueError, KeyError, TypeError)`-Behandlung in
  `routes.py::score()` bereits als 400 abgefangen — keine neue Fehlerbehandlung
  nötig). Reicht `green`/`yellow` an jeden `compute_cents_deviation(...)`- und
  `compute_glide(...)`-Aufruf innerhalb der Notenschleife durch.

### 3. API (`backend/api/routes.py`)

`ScoreRequest` bekommt ein neues optionales Feld:

```python
class ScoreRequest(BaseModel):
    target_curve: list[dict]
    sung_curve: list[dict]
    tolerance_preset: str = "normal"
```

`score()` reicht `body.tolerance_preset` an `score_performance(...)` durch.

### 4. Mobile (`mobile/lib/state/session_state.dart`, neues Enum, neue UI)

Neues Enum (Datei: `session_state.dart`, analog zum bestehenden
`ReferenceSource`-Muster):

```dart
enum TolerancePreset { strict, normal, loose }

extension TolerancePresetApi on TolerancePreset {
  String get apiValue => switch (this) {
    TolerancePreset.strict => 'strict',
    TolerancePreset.normal => 'normal',
    TolerancePreset.loose => 'loose',
  };

  String get label => switch (this) {
    TolerancePreset.strict => 'Streng',
    TolerancePreset.normal => 'Normal',
    TolerancePreset.loose => 'Locker',
  };
}
```

`SessionState.tolerancePreset` startet mit `TolerancePreset.normal`, wird aber
beim App-Start asynchron aus `SharedPreferences` überschrieben, falls dort
bereits eine Wahl gespeichert ist (Key `"tolerance_preset"`, Wert = `apiValue`).
Neue Abhängigkeit `shared_preferences: ^2.5.5` (Kompatibilität mit den
bestehenden `file_picker: 10.3.10`/`wakelock_plus: ^1.5.2`-Pins geprüft, löst
sauber auf).

Ein neuer `Future<void> setTolerancePreset(TolerancePreset preset)`:
1. Setzt `tolerancePreset = preset`, `notifyListeners()`.
2. Persistiert über `SharedPreferences.getInstance()` →
   `setString('tolerance_preset', preset.apiValue)`.
3. Falls bereits ein `scoreResult` vorliegt (bzw. `alignedSungCurve` nicht
   leer ist — gleiche Bedingung wie bei `setTranspose()`), automatisch
   `await score()` erneut auslösen, damit die Anzeige sofort die neue
   Klassifikation zeigt.

`ScoreApi.score(...)` (`mobile/lib/api/score_api.dart`) bekommt einen neuen
Parameter `tolerancePreset` (Typ `TolerancePreset`), sendet
`preset.apiValue` als `"tolerance_preset"`-Feld im JSON-Body.
`SessionState.score()` reicht `tolerancePreset` an `scoreApi.score(...)` durch.

UI: eine dreiteilige Auswahl (`SegmentedButton<TolerancePreset>`, gleiches
Widget-Muster wie der frühere Referenzquellen-Umschalter) direkt über der
`ScoreSummaryView` in `home_screen.dart`, mit den drei `label`-Texten aus dem
Enum. Tippen ruft `session.setTolerancePreset(...)` auf.

## Testing

- Backend (`tests/`): `classify_cents` an den Grenzwerten aller drei Presets
  (z. B. 25.0 Cent ist bei `normal` noch grün, bei `strict` schon gelb);
  `score_performance` mit identischer Eingabe und zwei verschiedenen Presets
  liefert unterschiedliche `cents_green`/`cents_yellow`/`cents_red`-Zähler und
  damit unterschiedlichen `overall_score`; ein unbekannter `tolerance_preset`
  löst über den `/api/score`-Endpunkt einen 400 aus (Funktionsaufruf-Test,
  Projekt-Konvention, kein `TestClient`).
- Mobile: `SessionState`-Test, dass `setTolerancePreset()` bei vorhandenem
  Score automatisch neu scort (gleiches Testmuster wie der bestehende
  `setTranspose()`-Test); Persistenz-Roundtrip (Preset setzen → neue
  `SessionState`-Instanz mit derselben `SharedPreferences`-Instanz liest
  denselben Wert); Widget-Test, dass die drei Labels sichtbar sind und Tippen
  `setTolerancePreset` mit dem richtigen Enum-Wert auslöst.

## Out of Scope (bewusst nicht Teil dieser Spec)

- Timing- (`TIMING_OK_THRESHOLD_MS`), Stabilitäts- (`STABILITY_MAD_THRESHOLD_CENTS`),
  Drift- (`DRIFT_FLAG_THRESHOLD_CENTS`) und Glide-Onset-Schwellen
  (`GLIDE_ONSET_THRESHOLD_CENTS`) skalieren NICHT mit dem Preset — nur die
  Grün/Gelb/Rot-Cents-Klassifikation (und, abgeleitet davon, der
  Glide-"sauber getroffen"-Check über denselben Grün-Wert).
- `MISSED_NOTE_CENTS_THRESHOLD` (300 Cent, Schwelle für "komplett verfehlt")
  bleibt unverändert und unabhängig vom Preset.
- Kein stufenloser Regler — nur die drei festen Presets.
- Keine Persistenz auf Server-/Konto-Ebene — rein lokal auf dem Gerät
  (`SharedPreferences`), da es keine Nutzerkonten gibt.
- Die Preset-Wahl wird in der Score-Antwort nicht zurückgespiegelt — der
  Client kennt sie bereits, da er sie selbst gesendet hat.

# Toleranz-Preset fuer die Cents-Bewertung Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ein einstellbares Toleranz-Preset (Streng/Normal/Locker), das nur die grün/gelb/rot-Klassifikation der Tonhöhen-Abweichung in der Bewertung beeinflusst, mit lokaler Persistenz auf dem Gerät.

**Architecture:** Backend: eine Preset-Tabelle in `config.py` ersetzt die zwei festen Cents-Schwellen; die Schwellen werden als Parameter durch `pitch.py`/`glides.py`/`score.py` gereicht statt als Modul-Konstanten gelesen; `POST /api/score` bekommt ein neues optionales Feld. Mobile: ein neues `TolerancePreset`-Enum (eigene Datei in `models/`, damit sowohl der State- als auch der API-Layer es importieren können ohne Zirkelbezug), `SessionState` haelt den aktuellen Wert, persistiert ihn ueber `shared_preferences` und triggert bei Aenderung automatisch ein erneutes `score()`; eine neue, von `SessionState` entkoppelte `SegmentedButton`-Widget-Komponente (Props-Pattern wie `TransposeControl`) sitzt ueber der Score-Zusammenfassung.

**Tech Stack:** Python/FastAPI (Backend), Flutter/Dart (Mobile), Paket `shared_preferences: ^2.5.5` (neu).

## Global Constraints

- Preset-Tabelle (Cents, exakt diese Werte):

  | Preset | grün ≤ | gelb ≤ |
  |---|---|---|
  | `strict` | 15.0 | 50.0 |
  | `normal` | 25.0 | 75.0 |
  | `loose` | 35.0 | 100.0 |

- Server- UND App-Default ist `"normal"` (`normal` = 25.0/75.0).
- Nur die grün/gelb/rot-Klassifikation der Cent-Abweichung (und, davon
  abgeleitet, der Glide-"sauber getroffen"-Check ueber denselben
  Grün-Schwellwert) skaliert mit dem Preset. `MISSED_NOTE_CENTS_THRESHOLD`
  sowie alle Timing-/Stabilitäts-/Drift-/Glide-Onset-Schwellen bleiben
  unveraendert und unabhaengig vom Preset.
- API-Feldname: `tolerance_preset` (String, einer von `"strict"`/`"normal"`/`"loose"`).
- Mobile SharedPreferences-Key: `"tolerance_preset"`, gespeicherter Wert = der
  API-String (z.B. `"strict"`).
- Kein `TestClient`/HTTP-Level-Test fuer den Endpunkt-Fehlerfall (Projekt-Konvention,
  siehe `docs/superpowers/specs/2026-08-07-track-scoring-and-preview-design.md`) —
  nur Funktionsaufruf-Tests.

---

### Task 1: Backend — Preset-Tabelle und Parameter-Durchreichung

**Files:**
- Modify: `backend/config.py:50-56`
- Modify: `backend/scoring/pitch.py`
- Modify: `backend/scoring/glides.py`
- Modify: `backend/scoring/score.py`
- Modify: `backend/api/routes.py`
- Test: `tests/test_scoring.py`

**Interfaces:**
- Produces: `backend.config.CENTS_TOLERANCE_PRESETS: dict[str, dict[str, float]]`,
  `backend.config.DEFAULT_CENTS_TOLERANCE_PRESET: str`.
- Produces: `classify_cents(value: float, green_threshold: float, yellow_threshold: float) -> str`
  (beide Parameter jetzt Pflicht, kein Default mehr).
- Produces: `compute_cents_deviation(note: dict, attributed_frames: list[dict], green_threshold: float, yellow_threshold: float) -> dict | None`.
- Produces: `compute_glide(note: dict, attributed_frames: list[dict], green_threshold: float) -> dict`.
- Produces: `score_performance(target_curve: list[dict], sung_curve: list[dict], frame_rate_hz: float = 100.0, tolerance_preset: str = DEFAULT_CENTS_TOLERANCE_PRESET) -> dict`
  — unbekannter `tolerance_preset` löst `KeyError` aus.

- [ ] **Step 1: Preset-Tabelle in config.py**

In `backend/config.py`, ersetze diesen Block (aktuell Zeilen 50-56):

```python
# Bewertungs-Engine: Cent-Abweichung & verfehlte Zielnoten.
CENTS_GREEN_THRESHOLD = 15.0
CENTS_YELLOW_THRESHOLD = 50.0
MISSED_NOTE_MIN_COVERAGE_FRACTION = 0.5
MISSED_NOTE_CENTS_THRESHOLD = 300.0
STABILITY_ONSET_TRIM_SECONDS = 0.05
```

durch:

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
MISSED_NOTE_MIN_COVERAGE_FRACTION = 0.5
MISSED_NOTE_CENTS_THRESHOLD = 300.0
STABILITY_ONSET_TRIM_SECONDS = 0.05
```

- [ ] **Step 2: classify_cents/compute_cents_deviation in pitch.py parametrisieren**

In `backend/scoring/pitch.py`, ersetze den Import-Block:

```python
from backend.config import (
    CENTS_GREEN_THRESHOLD,
    CENTS_YELLOW_THRESHOLD,
    MISSED_NOTE_CENTS_THRESHOLD,
    MISSED_NOTE_MIN_COVERAGE_FRACTION,
    STABILITY_ONSET_TRIM_SECONDS,
)
```

durch:

```python
from backend.config import (
    MISSED_NOTE_CENTS_THRESHOLD,
    MISSED_NOTE_MIN_COVERAGE_FRACTION,
    STABILITY_ONSET_TRIM_SECONDS,
)
```

Ersetze:

```python
def classify_cents(value: float) -> str:
    magnitude = abs(value)
    if magnitude <= CENTS_GREEN_THRESHOLD:
        return "green"
    if magnitude <= CENTS_YELLOW_THRESHOLD:
        return "yellow"
    return "red"
```

durch:

```python
def classify_cents(value: float, green_threshold: float, yellow_threshold: float) -> str:
    magnitude = abs(value)
    if magnitude <= green_threshold:
        return "green"
    if magnitude <= yellow_threshold:
        return "yellow"
    return "red"
```

Ersetze:

```python
def compute_cents_deviation(note: dict, attributed_frames: list[dict]) -> dict | None:
    """{'value': float, 'classification': str} oder None, wenn keine stimmhaften
    Frames zugeordnet werden konnten (dann greift stattdessen is_missed())."""
    deviations = sorted(_voiced_deviations(note, attributed_frames))
    if not deviations:
        return None
    median_value = deviations[len(deviations) // 2]
    return {"value": round(median_value, 1), "classification": classify_cents(median_value)}
```

durch:

```python
def compute_cents_deviation(
    note: dict, attributed_frames: list[dict], green_threshold: float, yellow_threshold: float,
) -> dict | None:
    """{'value': float, 'classification': str} oder None, wenn keine stimmhaften
    Frames zugeordnet werden konnten (dann greift stattdessen is_missed())."""
    deviations = sorted(_voiced_deviations(note, attributed_frames))
    if not deviations:
        return None
    median_value = deviations[len(deviations) // 2]
    classification = classify_cents(median_value, green_threshold, yellow_threshold)
    return {"value": round(median_value, 1), "classification": classification}
```

- [ ] **Step 3: compute_glide in glides.py parametrisieren**

In `backend/scoring/glides.py`, ersetze:

```python
from backend.config import (
    CENTS_GREEN_THRESHOLD,
    GLIDE_HEAD_SECONDS,
    GLIDE_MIN_HEAD_FRAMES,
    GLIDE_ONSET_THRESHOLD_CENTS,
)
```

durch:

```python
from backend.config import (
    GLIDE_HEAD_SECONDS,
    GLIDE_MIN_HEAD_FRAMES,
    GLIDE_ONSET_THRESHOLD_CENTS,
)
```

Ersetze die Funktionssignatur und die Flag-Zeile:

```python
def compute_glide(note: dict, attributed_frames: list[dict]) -> dict:
```

durch:

```python
def compute_glide(note: dict, attributed_frames: list[dict], green_threshold: float) -> dict:
```

und

```python
    flag = abs(head_median) > GLIDE_ONSET_THRESHOLD_CENTS and abs(rest_median) <= CENTS_GREEN_THRESHOLD
```

durch:

```python
    flag = abs(head_median) > GLIDE_ONSET_THRESHOLD_CENTS and abs(rest_median) <= green_threshold
```

- [ ] **Step 4: score_performance in score.py verdrahten**

In `backend/scoring/score.py`, füge nach dem letzten `from backend.scoring...`-Import
eine neue Import-Zeile hinzu:

```python
from backend.config import CENTS_TOLERANCE_PRESETS, DEFAULT_CENTS_TOLERANCE_PRESET
```

Ersetze die Funktionssignatur und den Beginn des Funktionskörpers:

```python
def score_performance(
    target_curve: list[dict], sung_curve: list[dict], frame_rate_hz: float = 100.0,
) -> dict:
    if sung_curve and any("aligned_t" not in frame for frame in sung_curve):
        raise ValueError(
            "sung_curve-Frames ohne 'aligned_t' - bitte zuerst align_curves() aufrufen."
        )

    vocal_range = compute_vocal_range(sung_curve)
```

durch:

```python
def score_performance(
    target_curve: list[dict], sung_curve: list[dict], frame_rate_hz: float = 100.0,
    tolerance_preset: str = DEFAULT_CENTS_TOLERANCE_PRESET,
) -> dict:
    if sung_curve and any("aligned_t" not in frame for frame in sung_curve):
        raise ValueError(
            "sung_curve-Frames ohne 'aligned_t' - bitte zuerst align_curves() aufrufen."
        )

    cents_thresholds = CENTS_TOLERANCE_PRESETS[tolerance_preset]
    green_threshold = cents_thresholds["green"]
    yellow_threshold = cents_thresholds["yellow"]

    vocal_range = compute_vocal_range(sung_curve)
```

Ersetze innerhalb der Notenschleife:

```python
        cents = compute_cents_deviation(note, attributed)
```

durch:

```python
        cents = compute_cents_deviation(note, attributed, green_threshold, yellow_threshold)
```

Ersetze:

```python
        glide = (
            compute_glide(note, attributed)
            if not missed
            and cents
            and cents["classification"] in ("green", "yellow")
            and timing_classification == "on_time"
            else dict(NOT_APPLICABLE_GLIDE)
        )
```

durch:

```python
        glide = (
            compute_glide(note, attributed, green_threshold)
            if not missed
            and cents
            and cents["classification"] in ("green", "yellow")
            and timing_classification == "on_time"
            else dict(NOT_APPLICABLE_GLIDE)
        )
```

- [ ] **Step 5: ScoreRequest um tolerance_preset erweitern**

In `backend/api/routes.py`, ersetze:

```python
class ScoreRequest(BaseModel):
    target_curve: list[dict]
    sung_curve: list[dict]  # muss die AUSGERICHTETE Kurve sein (aligned_t vorhanden)
```

durch:

```python
class ScoreRequest(BaseModel):
    target_curve: list[dict]
    sung_curve: list[dict]  # muss die AUSGERICHTETE Kurve sein (aligned_t vorhanden)
    tolerance_preset: str = "normal"
```

Ersetze:

```python
        result = score_performance(body.target_curve, body.sung_curve)
```

durch:

```python
        result = score_performance(
            body.target_curve, body.sung_curve, tolerance_preset=body.tolerance_preset,
        )
```

(Kein Änderungsbedarf an der `except (ValueError, KeyError, TypeError)`-Zeile
direkt darunter — sie fängt den `KeyError` eines unbekannten Presets bereits ab.)

- [ ] **Step 6: Bestehende Aufrufstellen in tests/test_scoring.py anpassen**

In `tests/test_scoring.py`, füge nach dem bestehenden
`from backend.config import MISSED_NOTE_MIN_COVERAGE_FRACTION` eine neue
Import-Zeile hinzu:

```python
from backend.config import CENTS_TOLERANCE_PRESETS
```

Ersetze:

```python
def test_classify_cents_boundaries():
    assert classify_cents(14.9) == "green"
    assert classify_cents(15.0) == "green"
    assert classify_cents(15.1) == "yellow"
    assert classify_cents(-49.9) == "yellow"
    assert classify_cents(50.0) == "yellow"
    assert classify_cents(50.1) == "red"
```

durch:

```python
def test_classify_cents_boundaries():
    assert classify_cents(14.9, green_threshold=15.0, yellow_threshold=50.0) == "green"
    assert classify_cents(15.0, green_threshold=15.0, yellow_threshold=50.0) == "green"
    assert classify_cents(15.1, green_threshold=15.0, yellow_threshold=50.0) == "yellow"
    assert classify_cents(-49.9, green_threshold=15.0, yellow_threshold=50.0) == "yellow"
    assert classify_cents(50.0, green_threshold=15.0, yellow_threshold=50.0) == "yellow"
    assert classify_cents(50.1, green_threshold=15.0, yellow_threshold=50.0) == "red"


def test_classify_cents_respects_different_presets():
    # Bei 30 Cent klassifiziert "strict" (15/50) gelb, "loose" (35/100) gruen -
    # derselbe Messwert, unterschiedliche Presets, unterschiedliches Ergebnis.
    strict = CENTS_TOLERANCE_PRESETS["strict"]
    loose = CENTS_TOLERANCE_PRESETS["loose"]
    assert classify_cents(30.0, strict["green"], strict["yellow"]) == "yellow"
    assert classify_cents(30.0, loose["green"], loose["yellow"]) == "green"
```

Ersetze:

```python
def test_compute_cents_deviation_uses_median_not_mean():
    note = {"start_t": 0.0, "end_t": 1.2, "hz": 440.0}
    frames = [_sung_frame(round(i * 0.01, 3), 440.0) for i in range(90)]
    # Letzte 30 Frames (Phrasenende) driften stark ab - Median soll das ignorieren.
    frames += [
        _sung_frame(round((90 + i) * 0.01, 3), 440.0 * 2 ** (-100 * (i / 30) / 1200))
        for i in range(30)
    ]
    result = compute_cents_deviation(note, frames)
    assert result is not None
    assert abs(result["value"]) < 5


def test_compute_cents_deviation_none_without_voiced_frames():
    note = {"start_t": 0.0, "end_t": 1.0, "hz": 440.0}
    frames = [_sung_frame(0.5, None, voiced=False)]
    assert compute_cents_deviation(note, frames) is None
```

durch:

```python
def test_compute_cents_deviation_uses_median_not_mean():
    note = {"start_t": 0.0, "end_t": 1.2, "hz": 440.0}
    frames = [_sung_frame(round(i * 0.01, 3), 440.0) for i in range(90)]
    # Letzte 30 Frames (Phrasenende) driften stark ab - Median soll das ignorieren.
    frames += [
        _sung_frame(round((90 + i) * 0.01, 3), 440.0 * 2 ** (-100 * (i / 30) / 1200))
        for i in range(30)
    ]
    normal = CENTS_TOLERANCE_PRESETS["normal"]
    result = compute_cents_deviation(note, frames, normal["green"], normal["yellow"])
    assert result is not None
    assert abs(result["value"]) < 5


def test_compute_cents_deviation_none_without_voiced_frames():
    note = {"start_t": 0.0, "end_t": 1.0, "hz": 440.0}
    frames = [_sung_frame(0.5, None, voiced=False)]
    normal = CENTS_TOLERANCE_PRESETS["normal"]
    assert compute_cents_deviation(note, frames, normal["green"], normal["yellow"]) is None
```

In den vier `compute_glide(...)`-Aufrufen (Funktionen
`test_compute_glide_flags_genuine_glide_and_reports_direction`,
`test_compute_glide_does_not_flag_clean_onset`,
`test_compute_glide_not_applicable_with_too_few_head_frames`,
`test_compute_glide_not_applicable_when_note_shorter_than_head_window`),
ersetze jeweils

```python
    result = compute_glide(note, head_frames + rest_frames)
```

(bzw. `compute_glide(note, frames)` in den beiden anderen Tests) durch die
gleiche Zeile mit einem zusätzlichen dritten Argument
`CENTS_TOLERANCE_PRESETS["normal"]["green"]`, z.B.:

```python
    result = compute_glide(note, head_frames + rest_frames, CENTS_TOLERANCE_PRESETS["normal"]["green"])
```

bzw.

```python
    result = compute_glide(note, frames, CENTS_TOLERANCE_PRESETS["normal"]["green"])
```

- [ ] **Step 7: Neue Preset-Tests für score_performance**

Füge in `tests/test_scoring.py` nach der bestehenden Funktion
`test_score_performance_includes_vocal_range_in_summary` (letzte Funktion der
Datei) folgende zwei Tests hinzu:

```python
def test_score_performance_tolerance_preset_changes_classification():
    # Dieselbe Eingabe (konstant +30 Cent zu hoch), zwei verschiedene Presets:
    # "strict" (15/50) klassifiziert gelb, "loose" (35/100) klassifiziert gruen.
    target_curve = _flat_curve(440.0, 100)
    off_pitch_hz = 440.0 * 2 ** (30 / 1200)
    sung_curve = [
        _sung_frame(round(i * 0.01, 3), off_pitch_hz, aligned_t=round(i * 0.01, 3))
        for i in range(100)
    ]

    strict_result = score_performance(target_curve, sung_curve, tolerance_preset="strict")
    loose_result = score_performance(target_curve, sung_curve, tolerance_preset="loose")

    assert strict_result["notes"][0]["cents_deviation"]["classification"] == "yellow"
    assert strict_result["summary"]["cents_yellow"] == 1
    assert loose_result["notes"][0]["cents_deviation"]["classification"] == "green"
    assert loose_result["summary"]["cents_green"] == 1


def test_score_performance_unknown_tolerance_preset_raises_key_error():
    target_curve = _flat_curve(440.0, 100)
    sung_curve = [
        _sung_frame(round(i * 0.01, 3), 440.0, aligned_t=round(i * 0.01, 3))
        for i in range(100)
    ]
    with pytest.raises(KeyError):
        score_performance(target_curve, sung_curve, tolerance_preset="unbekannt")
```

- [ ] **Step 8: Tests laufen lassen**

Run: `.venv/bin/pytest tests/test_scoring.py tests/test_e2e_phase4.py -v`
Expected: alle Tests PASS (inkl. der 4 neuen/geänderten und der 2 neuen Tests
aus Step 7; `test_e2e_phase4.py` ruft `score_performance` ohne
`tolerance_preset` auf und bleibt unverändert grün, da 40 Cent sowohl unter
den alten 15/50- als auch den neuen 25/75-Normal-Schwellen "yellow" ergibt).

- [ ] **Step 9: Commit**

```bash
git add backend/config.py backend/scoring/pitch.py backend/scoring/glides.py backend/scoring/score.py backend/api/routes.py tests/test_scoring.py
git commit -m "feat: add configurable cents-tolerance presets to the scoring engine"
```

---

### Task 2: Mobile — TolerancePreset-Enum, Persistenz, State-Verdrahtung

**Files:**
- Create: `mobile/lib/models/tolerance_preset.dart`
- Modify: `mobile/pubspec.yaml`
- Modify: `mobile/lib/api/score_api.dart`
- Modify: `mobile/lib/state/session_state.dart`
- Modify: `mobile/lib/main.dart`
- Test: `mobile/test/session_state_test.dart`

**Interfaces:**
- Consumes: nichts aus Task 1 (Mobile und Backend sind über den JSON-Feldnamen
  `tolerance_preset` entkoppelt, kein gemeinsamer Code).
- Produces: `enum TolerancePreset { strict, normal, loose }` mit
  `String get apiValue`, `String get label`,
  `static TolerancePreset? fromApiValue(String? value)` — Task 3 importiert
  dieses Enum aus `mobile/lib/models/tolerance_preset.dart`.
- Produces: `SessionState.tolerancePreset` (Feld, Default
  `TolerancePreset.normal`), `Future<void> SessionState.setTolerancePreset(TolerancePreset preset)`,
  `Future<void> SessionState.loadPersistedTolerancePreset()` — Task 3 ruft
  `setTolerancePreset` aus der UI auf.

- [ ] **Step 1: Abhängigkeit hinzufügen**

In `mobile/pubspec.yaml`, im `dependencies:`-Block, nach der Zeile
`wakelock_plus: ^1.5.2` (bzw. deren Kommentarzeilen) folgende Zeile einfügen:

```yaml
  shared_preferences: ^2.5.5
```

Dann ausführen: `cd mobile && flutter pub get`

- [ ] **Step 2: TolerancePreset-Enum**

Neue Datei `mobile/lib/models/tolerance_preset.dart`:

```dart
/// Toleranz-Preset fuer die gruen/gelb/rot-Klassifikation der Cent-Abweichung
/// in der Bewertung (siehe
/// docs/superpowers/specs/2026-08-07-tolerance-preset-design.md). Eigene Datei
/// (statt inline in session_state.dart wie ReferenceSource), weil sowohl
/// SessionState als auch ScoreApi dieses Enum brauchen und ScoreApi
/// SessionState nicht importieren darf (Zirkelbezug).
enum TolerancePreset {
  strict,
  normal,
  loose;

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

  static TolerancePreset? fromApiValue(String? value) {
    for (final preset in TolerancePreset.values) {
      if (preset.apiValue == value) return preset;
    }
    return null;
  }
}
```

- [ ] **Step 3: ScoreApi.score() um tolerancePreset erweitern**

In `mobile/lib/api/score_api.dart`, ersetze die gesamte Datei durch:

```dart
import '../models/score_result.dart';
import '../models/sung_point.dart';
import '../models/tolerance_preset.dart';
import 'api_client.dart';

/// Ruft POST /api/score auf (backend/api/routes.py::score) und liefert das
/// geparste Bewertungsergebnis. Nimmt die Zielkurve als bereits serialisiertes
/// JSON entgegen (nicht als TargetPoint-Liste), da der Aufrufer je nach Modus
/// entweder TargetPoint- oder SungPoint-Objekte serialisiert (siehe SessionState.score()).
class ScoreApi {
  final ApiClient _client;

  ScoreApi(this._client);

  Future<ScoreResult> score(
    List<Map<String, dynamic>> targetCurveJson,
    List<SungPoint> alignedSungCurve,
    TolerancePreset tolerancePreset,
  ) async {
    final json = await _client.postJson('/api/score', {
      'target_curve': targetCurveJson,
      'sung_curve': alignedSungCurve.map((p) => p.toJson()).toList(),
      'tolerance_preset': tolerancePreset.apiValue,
    });
    return ScoreResult.fromJson(json['score'] as Map<String, dynamic>);
  }
}
```

- [ ] **Step 4: SessionState — Import, Feld, Prefs-Key**

In `mobile/lib/state/session_state.dart`, füge nach den bestehenden
`import`-Zeilen am Dateianfang eine neue Zeile hinzu:

```dart
import 'package:shared_preferences/shared_preferences.dart';
```

(Import-Pfad zu `models/tolerance_preset.dart` ebenfalls ergänzen, an der
Stelle, wo bereits andere `models/`-Importe stehen, z.B. neben dem Import von
`ScoreResult` — exakter Ort ist Implementierungsdetail, Hauptsache
`import '../models/tolerance_preset.dart';` existiert.)

Füge direkt nach der bestehenden Zeile

```dart
enum ReferenceSource { midi, recording }
```

folgende neue top-level Konstante ein:

```dart
const String _tolerancePresetPrefsKey = 'tolerance_preset';
```

Füge das neue Feld direkt vor der bestehenden Zeile `ScoreResult? scoreResult;`
ein:

```dart
  /// Toleranz-Preset fuer die gruen/gelb/rot-Klassifikation der Cent-Abweichung
  /// (siehe docs/superpowers/specs/2026-08-07-tolerance-preset-design.md).
  /// Startet synchron mit dem Default; ein zuvor gespeicherter Wert wird erst
  /// asynchron per loadPersistedTolerancePreset() nachgeladen (siehe dort).
  TolerancePreset tolerancePreset = TolerancePreset.normal;
```

- [ ] **Step 5: setTolerancePreset/loadPersistedTolerancePreset**

Füge in `mobile/lib/state/session_state.dart` direkt nach der bestehenden
Methode `_reloadTargetCurve()` (nach deren schließender `}`, vor der
Doc-Comment-Zeile `/// Auto-Trigger wie bei align()/score()...` über `score()`)
folgende zwei neue Methoden ein:

```dart
  Future<void> setTolerancePreset(TolerancePreset preset) async {
    tolerancePreset = preset;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tolerancePresetPrefsKey, preset.apiValue);
    if (alignedSungCurve.isNotEmpty) await score();
  }

  /// Laedt ein zuvor gespeichertes Toleranz-Preset (falls vorhanden) und wendet
  /// es an - bewusst NICHT im Konstruktor, sondern nur von main.dart nach dem
  /// Bauen dieser SessionState aufgerufen (fire-and-forget), damit kein Test,
  /// der eine SessionState baut, ungewollt einen SharedPreferences-
  /// Plattform-Kanal-Zugriff ausloest (gleiches Prinzip wie beim lazy
  /// _playbackController weiter oben in dieser Datei).
  Future<void> loadPersistedTolerancePreset() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = TolerancePreset.fromApiValue(prefs.getString(_tolerancePresetPrefsKey));
    if (stored != null && stored != tolerancePreset) {
      tolerancePreset = stored;
      notifyListeners();
    }
  }
```

- [ ] **Step 6: score() reicht tolerancePreset an ScoreApi durch**

In `mobile/lib/state/session_state.dart`, ersetze innerhalb von `score()`:

```dart
      scoreResult = await scoreApi.score(targetCurveJson, alignedSungCurve);
```

durch:

```dart
      scoreResult = await scoreApi.score(targetCurveJson, alignedSungCurve, tolerancePreset);
```

- [ ] **Step 7: main.dart laedt das persistierte Preset beim Start**

In `mobile/lib/main.dart`, füge nach der bestehenden Zeile `import 'package:provider/provider.dart';`
eine neue Zeile hinzu:

```dart
import 'dart:async';
```

Ersetze:

```dart
    return ChangeNotifierProvider(
      create: (_) => SessionState(
        midiApi: MidiApi(apiClient),
        audioApi: AudioApi(apiClient),
        syncApi: SyncApi(apiClient),
        scoreApi: ScoreApi(apiClient),
        feedbackApi: FeedbackApi(apiClient),
      ),
```

durch:

```dart
    return ChangeNotifierProvider(
      create: (_) {
        final session = SessionState(
          midiApi: MidiApi(apiClient),
          audioApi: AudioApi(apiClient),
          syncApi: SyncApi(apiClient),
          scoreApi: ScoreApi(apiClient),
          feedbackApi: FeedbackApi(apiClient),
        );
        unawaited(session.loadPersistedTolerancePreset());
        return session;
      },
```

- [ ] **Step 8: Fehlschlagende Tests schreiben**

In `mobile/test/session_state_test.dart`, füge nach der bestehenden
Import-Zeile `import 'package:singing_feedback_mobile/state/session_state.dart';`
zwei neue Import-Zeilen hinzu:

```dart
import 'package:shared_preferences/shared_preferences.dart';
import 'package:singing_feedback_mobile/models/tolerance_preset.dart';
```

Füge als allererste Zeile innerhalb von `void main() {` (vor dem ersten
bestehenden `test(...)`) folgende Zeile ein:

```dart
  SharedPreferences.setMockInitialValues({});
```

Ersetze das Ende der Datei (die letzte Test-Funktion, gefolgt von den zwei
schließenden Klammern von `group('SessionState Aufnahme-Kuerzung', ...)` und
`void main() {`):

```dart
    test('analyzeAudio() setzt audioTruncated NICHT, wenn nicht gekuerzt wurde', () async {
      final client = _FakeApiClient();
      final session = SessionState(
        midiApi: MidiApi(client),
        audioApi: AudioApi(client),
        syncApi: SyncApi(client),
        scoreApi: ScoreApi(client),
        feedbackApi: FeedbackApi(client),
      );

      await session.analyzeAudio(Uint8List.fromList([1, 2, 3]), 'gesang.m4a');

      expect(session.audioTruncated, isFalse);
      expect(session.audioStatus, LoadStatus.ok);
    });
  });
}
```

durch denselben Text plus eine neue Gruppe davor eingefügt (achte darauf,
dass am Ende weiterhin genau eine schließende `}` für `void main()` steht,
nicht zwei):

```dart
    test('analyzeAudio() setzt audioTruncated NICHT, wenn nicht gekuerzt wurde', () async {
      final client = _FakeApiClient();
      final session = SessionState(
        midiApi: MidiApi(client),
        audioApi: AudioApi(client),
        syncApi: SyncApi(client),
        scoreApi: ScoreApi(client),
        feedbackApi: FeedbackApi(client),
      );

      await session.analyzeAudio(Uint8List.fromList([1, 2, 3]), 'gesang.m4a');

      expect(session.audioTruncated, isFalse);
      expect(session.audioStatus, LoadStatus.ok);
    });
  });

  group('SessionState Toleranz-Preset', () {
    test('tolerancePreset startet mit TolerancePreset.normal', () {
      final session = _buildSession();
      expect(session.tolerancePreset, TolerancePreset.normal);
    });

    test('setTolerancePreset loest bei vorhandenem Score ein erneutes score() '
        'aus und sendet das Preset mit', () async {
      final client = _FakeApiClient();
      final session = SessionState(
        midiApi: MidiApi(client),
        audioApi: AudioApi(client),
        syncApi: SyncApi(client),
        scoreApi: ScoreApi(client),
        feedbackApi: FeedbackApi(client),
      );
      session.setReferenceSource(ReferenceSource.midi);
      session.midiSessionId = 'sess-1';
      session.selectedTrackIndex = 0;
      session.targetCurve = const [TargetPoint(t: 0.0, hz: 440.0, midiNote: 69)];
      await session.analyzeAudio(Uint8List.fromList([1, 2, 3]), 'gesang.wav');
      expect(session.scoreResult, isNotNull);

      await session.setTolerancePreset(TolerancePreset.strict);

      expect(session.tolerancePreset, TolerancePreset.strict);
      expect(client.lastPostJsonBody?['tolerance_preset'], 'strict');
    });

    test('setTolerancePreset persistiert das Preset, eine neue SessionState-Instanz '
        'laedt es per loadPersistedTolerancePreset() zurueck', () async {
      final sessionA = _buildSession();
      await sessionA.setTolerancePreset(TolerancePreset.loose);

      final sessionB = _buildSession();
      expect(sessionB.tolerancePreset, TolerancePreset.normal,
          reason: 'vor dem Laden noch der Default');
      await sessionB.loadPersistedTolerancePreset();

      expect(sessionB.tolerancePreset, TolerancePreset.loose);
    });

    test('loadPersistedTolerancePreset() aendert nichts, wenn nie etwas '
        'gespeichert wurde', () async {
      SharedPreferences.setMockInitialValues({});
      final session = _buildSession();

      await session.loadPersistedTolerancePreset();

      expect(session.tolerancePreset, TolerancePreset.normal);
    });
  });
}
```

- [ ] **Step 9: Tests laufen lassen, Fehlschlag/Erfolg prüfen**

Run: `cd mobile && flutter pub get && flutter test test/session_state_test.dart`
Expected: PASS, alle bisherigen Tests weiterhin grün plus die 4 neuen Tests
aus der Gruppe `SessionState Toleranz-Preset`.

- [ ] **Step 10: Volle Testsuite laufen lassen**

Run: `cd mobile && flutter test`
Expected: PASS (keine anderen Testdateien betroffen, da `SessionState`s
Konstruktor selbst keinen `SharedPreferences`-Zugriff auslöst — nur
`setTolerancePreset`/`loadPersistedTolerancePreset`, die ausschließlich in
`session_state_test.dart` aufgerufen werden).

- [ ] **Step 11: Commit**

```bash
cd mobile && git add pubspec.yaml pubspec.lock lib/models/tolerance_preset.dart lib/api/score_api.dart lib/state/session_state.dart lib/main.dart test/session_state_test.dart
git commit -m "feat: add TolerancePreset state, persistence, and API wiring"
```

---

### Task 3: Mobile — UI-Auswahl über der Bewertung

**Files:**
- Create: `mobile/lib/widgets/tolerance_preset_control.dart`
- Modify: `mobile/lib/screens/home_screen.dart`
- Test: `mobile/test/tolerance_preset_control_test.dart`

**Interfaces:**
- Consumes: `TolerancePreset` (aus `mobile/lib/models/tolerance_preset.dart`,
  Task 2), `SessionState.tolerancePreset`/`setTolerancePreset` (Task 2).
- Produces: `class TolerancePresetControl extends StatelessWidget` mit
  Konstruktor `TolerancePresetControl({required TolerancePreset value, required ValueChanged<TolerancePreset> onChanged})`.

- [ ] **Step 1: Fehlschlagende Widget-Tests schreiben**

Neue Datei `mobile/test/tolerance_preset_control_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singing_feedback_mobile/models/tolerance_preset.dart';
import 'package:singing_feedback_mobile/widgets/tolerance_preset_control.dart';

void main() {
  testWidgets('zeigt alle drei Preset-Labels an', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TolerancePresetControl(value: TolerancePreset.normal, onChanged: (_) {}),
      ),
    ));

    expect(find.text('Streng'), findsOneWidget);
    expect(find.text('Normal'), findsOneWidget);
    expect(find.text('Locker'), findsOneWidget);
  });

  testWidgets('Tippen auf ein anderes Preset ruft onChanged mit dem richtigen Wert auf',
      (tester) async {
    TolerancePreset? changedTo;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TolerancePresetControl(
          value: TolerancePreset.normal,
          onChanged: (preset) => changedTo = preset,
        ),
      ),
    ));

    await tester.tap(find.text('Streng'));
    await tester.pump();

    expect(changedTo, TolerancePreset.strict);
  });
}
```

- [ ] **Step 2: Test laufen lassen, Fehlschlag bestätigen**

Run: `cd mobile && flutter test test/tolerance_preset_control_test.dart`
Expected: FAIL (Datei `lib/widgets/tolerance_preset_control.dart` existiert
noch nicht, Compile-Fehler "Target of URI doesn't exist").

- [ ] **Step 3: TolerancePresetControl implementieren**

Neue Datei `mobile/lib/widgets/tolerance_preset_control.dart`:

```dart
import 'package:flutter/material.dart';

import '../models/tolerance_preset.dart';

/// Steuert die Toleranz fuer die gruen/gelb/rot-Klassifikation der Cent-
/// Abweichung in der Bewertung (siehe
/// docs/superpowers/specs/2026-08-07-tolerance-preset-design.md). Reines
/// Props-Widget (kein direkter SessionState-Zugriff), gleiches Muster wie
/// TransposeControl.
class TolerancePresetControl extends StatelessWidget {
  final TolerancePreset value;
  final ValueChanged<TolerancePreset> onChanged;

  const TolerancePresetControl({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<TolerancePreset>(
      segments: TolerancePreset.values
          .map((preset) => ButtonSegment(value: preset, label: Text(preset.label)))
          .toList(),
      selected: {value},
      onSelectionChanged: (selection) => onChanged(selection.first),
    );
  }
}
```

- [ ] **Step 4: Test laufen lassen, Erfolg bestätigen**

Run: `cd mobile && flutter test test/tolerance_preset_control_test.dart`
Expected: PASS (2 Tests)

- [ ] **Step 5: In home_screen.dart einbinden**

In `mobile/lib/screens/home_screen.dart`, füge nach der bestehenden
Import-Zeile `import '../widgets/score_summary_view.dart';` eine neue
Zeile hinzu:

```dart
import '../widgets/tolerance_preset_control.dart';
```

Ersetze:

```dart
            StatusBanner(status: session.scoreStatus, message: session.scoreMessage),
            if (session.scoreResult != null) ScoreSummaryView(result: session.scoreResult!),
```

durch:

```dart
            StatusBanner(status: session.scoreStatus, message: session.scoreMessage),
            TolerancePresetControl(
              value: session.tolerancePreset,
              onChanged: (preset) => session.setTolerancePreset(preset),
            ),
            if (session.scoreResult != null) ScoreSummaryView(result: session.scoreResult!),
```

- [ ] **Step 6: Volle Testsuite laufen lassen**

Run: `cd mobile && flutter test`
Expected: PASS (alle bisherigen Tests weiterhin grün, plus die 2 neuen
Tests aus Task 3; `widget_test.dart` pumpt `SingingFeedbackApp`, was jetzt
auch `TolerancePresetControl` rendert — es tippt aber auf nichts Neues, nur
`find.text('Aufnehmen')` bleibt relevant, unverändert).

- [ ] **Step 7: Commit**

```bash
cd mobile && git add lib/widgets/tolerance_preset_control.dart lib/screens/home_screen.dart test/tolerance_preset_control_test.dart
git commit -m "feat: add tolerance-preset selector above the score summary"
```

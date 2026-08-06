# DTW-Drift bei Pausen begrenzen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `librosa.sequence.dtw`'s Ausrichtungspfad in `backend/sync/align.py::align_curves` bekommt eine Sakoe-Chiba-Bandbegrenzung, damit er auf längeren, echten Aufnahmen mit Pausen nicht mehr unbegrenzt driftet (real beobachtet: bis zu 18,7s Verschiebung bei einer 20s-Stille).

**Architecture:** Reine Backend-Änderung — eine neue Konfigurationskonstante (`DTW_BAND_RADIUS`) plus zwei zusätzliche Parameter am bestehenden `librosa.sequence.dtw`-Aufruf. Kein API-/Mobile-Impact.

**Tech Stack:** Python, `librosa` (bereits Pflichtabhängigkeit, keine neue).

## Global Constraints

- Reine Backend-Änderung, keine Mobile-/API-Auswirkung.
- `librosa.sequence.dtw`'s `band_rad`-Parameter wird nur wirksam, wenn zusätzlich `global_constraints=True` gesetzt ist (sonst Default `False`, `band_rad` wird sonst komplett ignoriert) — beide Parameter müssen zusammen gesetzt werden.
- Bandradius ist ein Bruchteil der kürzeren Kurvenlänge (`radius_frames = int(band_rad * min(len(X), len(Y)))`), skaliert also automatisch mit der Aufnahmedauer.
- Bestehende Tests dürfen nicht regressieren: `tests/test_e2e_phase3.py` (150ms-früh-Korrektur bei Note 2) und `tests/test_sync.py`'s bestehende `align_curves`-Tests müssen weiterhin grün bleiben.
- `duration_ratio_exceeds_limit`/`MAX_DURATION_RATIO` (bestehender Guard gegen grob unterschiedliche Gesamtdauern) bleibt unverändert — orthogonal zu diesem Fix.
- Keine UI-Änderung, keine Erkennung/Anzeige von "unsicherer Ausrichtung" — bewusst nicht Teil dieser Runde.

---

### Task 1: Den Drift in einem schnellen Selbst-Ausrichtungstest reproduzieren (noch ohne Fix)

**Files:**
- Modify: `tests/fixtures/generate_fixtures.py` (neue Pausen-Fixture-Funktionen anhängen)
- Modify: `tests/test_sync.py` (neuer Test anhängen)

**Interfaces:**
- Consumes: `backend.audio_io.load_audio_signal`, `backend.pitch_detection.pitch_curve_from_signal`, `backend.sync.{align_curves, onset_envelope_from_signal}` (alle bestehend, unverändert in diesem Task).
- Produces: `tests.fixtures.generate_fixtures.generate_pause_test_wav(output_dir: Path = FIXTURES_DIR) -> Path` — neue Fixture-Funktion, die spätere Tasks/Tests ebenfalls nutzen können.

Dieser Task liefert **absichtlich noch keinen Fix** — er beweist zuerst kontrolliert und schnell (ohne echtes Telefon), dass der real beobachtete Drift reproduzierbar ist. Die Fixture nutzt **Selbst-Ausrichtung**: dieselbe synthetische Aufnahme wird als Ziel- UND Gesangskurve verwendet. Bei perfekter Übereinstimmung müsste `aligned_t - t` überall nahe 0 bleiben, auch während/nach einer langen gemeinsamen Stille — jede nennenswerte Abweichung ist dann eindeutig ein DTW-Artefakt, keine "echte" Gesangsungenauigkeit.

- [ ] **Step 1: Pausen-Fixture an `tests/fixtures/generate_fixtures.py` anhängen**

Am Dateiende anfügen (nutzt die bereits vorhandenen `_sine_segment`, `SAMPLE_RATE`, `FIXTURES_DIR`, `np`, `pretty_midi`, `sf`, `Path` — keine neuen Imports nötig):

```python

# --- Pausen-Fixture (Bugfix: DTW-Drift bei Pausen, Phase 3) ---
#
# Kurze Melodie vor und nach einer langen (12s) gemeinsamen Stille - simuliert einen
# Instrumentalteil, in dem weder Referenz noch Gesang klingen (der reale, auf einem
# Telefon beobachtete Fall: 61s-Aufnahme mit 20s Stille, bis zu 18.7s DTW-Drift).

PAUSE_TEST_TOTAL_DURATION = 24.0

_PAUSE_MELODY = [
    (0.0, 2.0, 60),   # C4
    (2.0, 2.0, 64),   # E4
    (4.0, 2.0, 67),   # G4
    # 6.0-18.0s: Stille (12s Luecke)
    (18.0, 2.0, 67),  # G4
    (20.0, 2.0, 64),  # E4
    (22.0, 2.0, 60),  # C4
]


def build_pause_test_wav(sr: int = SAMPLE_RATE) -> np.ndarray:
    """Synthetische Aufnahme mit derselben kurzen Melodie vor und nach einer 12s-
    Stille. Wird in Tests als Ziel- UND Gesangskurve zugleich verwendet (Selbst-
    Ausrichtung), um Referenzaufnahme-Modus nachzubilden (beide Kurven ueber echtes
    Audio/pYIN/onset_strength, nicht ueber MIDI-Symbolik - genau der Pfad, auf dem der
    reale Drift beobachtet wurde)."""
    audio = np.zeros(int(PAUSE_TEST_TOTAL_DURATION * sr) + 1)
    for start, duration, note in _PAUSE_MELODY:
        base_hz = pretty_midi.note_number_to_hz(note)
        freq_fn = lambda t, hz=base_hz: np.full_like(t, hz)
        segment = _sine_segment(freq_fn, duration, sr)
        start_sample = int(start * sr)
        end_sample = start_sample + len(segment)
        if end_sample > len(audio):
            audio = np.pad(audio, (0, end_sample - len(audio)))
        audio[start_sample:end_sample] += segment
    return audio


def generate_pause_test_wav(output_dir: Path = FIXTURES_DIR) -> Path:
    output_dir.mkdir(parents=True, exist_ok=True)
    wav_path = output_dir / "test_pause.wav"
    audio = build_pause_test_wav()
    sf.write(str(wav_path), audio, SAMPLE_RATE)
    return wav_path
```

- [ ] **Step 2: Test an `tests/test_sync.py` anhängen**

Import-Block am Dateianfang (`tests/test_sync.py:1-16`) um die neuen Namen ergänzen:

```python
"""Tests fuer die DTW-Ausrichtung (Phase 3): Onset-Huellkurven + align_curves."""

from __future__ import annotations

from pathlib import Path

import numpy as np
import pretty_midi
import pytest

from backend.audio_io import load_audio_signal
from backend.pitch_detection import pitch_curve_from_signal
from backend.sync import (
    MAX_DURATION_RATIO,
    align_curves,
    duration_ratio_exceeds_limit,
    onset_envelope_from_midi_track,
    onset_envelope_from_signal,
)
from backend.midi_analysis import track_pitch_curve

from .fixtures.generate_fixtures import generate_pause_test_wav

FIXTURES_DIR = Path(__file__).resolve().parent / "fixtures"
```

(Nur die neuen Importzeilen `Path`, `load_audio_signal`, `pitch_curve_from_signal`, `generate_pause_test_wav` und die Konstante `FIXTURES_DIR` sind neu — der Rest des bestehenden Import-Blocks bleibt unverändert.)

Am Dateiende anfügen:

```python


def test_align_curves_self_alignment_stays_near_zero_through_a_long_pause():
    """Realer Bug: DTW driftete auf einer 61s-Aufnahme mit 20s Stille um bis zu 18.7s
    (siehe docs/superpowers/specs/2026-08-06-dtw-drift-band-fix-design.md). Reproduziert
    das in Miniatur mit Selbst-Ausrichtung (identische Kurve als Ziel und Gesang) - bei
    perfekter Uebereinstimmung MUESSTE aligned_t - t ueberall nahe 0 bleiben, auch
    waehrend/nach einer langen gemeinsamen Stille."""
    wav_path = generate_pause_test_wav(FIXTURES_DIR)
    y, sr = load_audio_signal(wav_path.read_bytes(), filename_hint="test_pause.wav")
    curve = pitch_curve_from_signal(y, sr, frame_rate_hz=100.0)
    envelope = onset_envelope_from_signal(y, sr, frame_rate_hz=100.0)

    result = align_curves(curve, envelope, curve, envelope)
    aligned = result["sung_curve"]

    deltas = [abs(f["aligned_t"] - f["t"]) for f in aligned if f["aligned_t"] is not None]
    assert deltas, "kein einziger Frame wurde ausgerichtet - Fixture oder Pipeline kaputt"
    max_drift = max(deltas)
    assert max_drift < 1.0, (
        f"Selbst-Ausrichtung sollte ueberall nahezu perfekt sein (Drift < 1s), "
        f"tatsaechlich max. {max_drift:.2f}s - DTW driftet waehrend/nach der Pause."
    )
```

- [ ] **Step 3: Test laufen lassen — FAIL erwarten (das ist der Beweis, kein Fehler)**

Run: `.venv/bin/pytest tests/test_sync.py -v -k self_alignment_stays_near_zero`

Erwartung: **FAIL** mit einem `max_drift`-Wert deutlich über 1.0s (die genaue Zahl hängt von librosa-internen Details ab, sollte aber in einer ähnlichen Größenordnung wie die real beobachteten Sekunden-Werte liegen, nicht Millisekunden). Das ist der gewünschte RED-Schritt: er beweist, dass der Bug jetzt kontrolliert und schnell (Sekunden statt eines Telefontests) reproduzierbar ist, bevor in Task 2 der Fix kommt.

**Falls der Test unerwartet PASST** (kein signifikanter Drift gemessen): die Fixture reproduziert den Bug in dieser Form nicht zuverlässig genug. Passe `_PAUSE_MELODY`/`PAUSE_TEST_TOTAL_DURATION` an (z.B. längere Pause, z.B. 15-18s statt 12s) und wiederhole Step 3, bis ein klarer Drift (mehrere Sekunden) beobachtbar ist — miss den tatsächlichen `max_drift`-Wert (z.B. per temporärem `print(max_drift)`) statt zu raten.

- [ ] **Step 4: Commit**

```bash
git add tests/fixtures/generate_fixtures.py tests/test_sync.py
git commit -m "test: reproduce DTW drift during long pauses (fails, fix follows)"
```

---

### Task 2: Sakoe-Chiba-Bandbegrenzung anwenden und beide Test-Suiten grün bekommen

**Files:**
- Modify: `backend/config.py` (neue Konstante anhängen)
- Modify: `backend/sync/align.py:63` (der bestehende `librosa.sequence.dtw`-Aufruf)

**Interfaces:**
- Consumes: `tests.test_sync.test_align_curves_self_alignment_stays_near_zero_through_a_long_pause` (Task 1, muss danach PASS liefern).
- Produces: nichts Neues nach außen — `align_curves()`s Signatur/Rückgabeform bleibt unverändert, nur ihr internes DTW-Verhalten ändert sich.

- [ ] **Step 1: Konstante in `backend/config.py` ergänzen (am Dateiende)**

```python

# DTW-Ausrichtung (Phase 3): Sakoe-Chiba-Bandradius, um den Ausrichtungspfad nah an
# der Diagonale zu halten. Ohne Begrenzung kann der Pfad in laengeren, echten
# Aufnahmen mit Pausen/stillen Abschnitten (wenig Onset-Signal als Kostendruck)
# beliebig weit "wegdriften" - real beobachtet: bis zu 18.7s Verschiebung auf einer
# 61s-Aufnahme mit 20s Stille (siehe docs/superpowers/specs/2026-08-06-dtw-drift-band-fix-design.md).
# Bruchteil der kuerzeren Kurvenlaenge (radius_frames = int(band_rad * min(len(X), len(Y)))),
# skaliert also automatisch mit der Aufnahmedauer.
DTW_BAND_RADIUS = 0.1
```

- [ ] **Step 2: `backend/sync/align.py` — den bestehenden DTW-Aufruf erweitern**

Import ergänzen (`backend/sync/align.py:1-6`, nach den bestehenden Imports):

```python
from backend.config import DTW_BAND_RADIUS
```

Den bestehenden Aufruf (`backend/sync/align.py:63`):

```python
    _, wp = librosa.sequence.dtw(X=x, Y=y, metric="euclidean", subseq=False, backtrack=True)
```

ersetzen durch:

```python
    _, wp = librosa.sequence.dtw(
        X=x, Y=y, metric="euclidean", subseq=False, backtrack=True,
        global_constraints=True, band_rad=DTW_BAND_RADIUS,
    )
```

- [ ] **Step 3: Task 1s Reproduktionstest erneut laufen lassen — jetzt PASS erwarten**

Run: `.venv/bin/pytest tests/test_sync.py -v -k self_alignment_stays_near_zero`

Erwartung: PASS (`max_drift < 1.0`).

**Falls weiterhin FAIL:** `DTW_BAND_RADIUS` in `backend/config.py` schrittweise verkleinern (z.B. 0.05) und Step 3 wiederholen — dabei aber nach jeder Änderung auch Step 4 (unten) mit ausführen, um sicherzustellen, dass der bestehende 150ms-Test nicht durch einen zu engen Radius kaputtgeht. Nicht einfach die `1.0`-Schwelle im Test aufweiten, um ihn künstlich grün zu bekommen — das Ziel ist ein echter, eng begrenzter Drift, keine kosmetisch angepasste Assertion.

- [ ] **Step 4: Regressionsschutz — bestehende Tests laufen lassen**

Run: `.venv/bin/pytest tests/test_sync.py tests/test_e2e_phase3.py -v`

Erwartung: **alle** Tests PASS, insbesondere `test_dtw_alignment_recovers_early_onset_and_leaves_correct_notes_unshifted` (die 150ms-früh-Korrektur aus der bestehenden 5s-Fixture muss weiterhin funktionieren — das ist der eigentliche Regressionsschutz für Phase 3).

- [ ] **Step 5: Vollständiger Testlauf zur Sicherheit**

Run: `.venv/bin/pytest tests/ -q`

Erwartung: alle Tests PASS (keine Regression in Phase 1/4, die ebenfalls indirekt von `align_curves()` abhängen — Phase 4s `tests/test_e2e_phase4.py` nutzt `align_curves()` ebenfalls).

- [ ] **Step 6: Commit**

```bash
git add backend/config.py backend/sync/align.py
git commit -m "fix: bound DTW warping path with Sakoe-Chiba band to prevent drift during pauses"
```

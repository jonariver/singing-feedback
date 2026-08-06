# DTW-Zeitausrichtung Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Die gesungene Tonhöhenkurve wird per DTW auf die Zeitachse der Zielmelodie (MIDI oder Referenzaufnahme) ausgerichtet, statt roh/unaligned angezeigt zu werden — nur im Mobile-Client.

**Architecture:** DTW läuft auf einer tonhöhen-unabhängigen Onset-Hüllkurve (aus MIDI-Note-Onsets synthetisch, aus Audio via `librosa.onset.onset_strength`), nicht auf der Rohtonhöhe. Ein neuer Backend-Endpunkt `POST /api/sync/align` liefert die gesungene Kurve mit einem zusätzlichen `aligned_t`-Feld pro Frame zurück; der Mobile-Client zeichnet die gesungene Serie damit statt mit der rohen Aufnahmezeit.

**Tech Stack:** Python/FastAPI (`librosa.sequence.dtw`, `librosa.onset.onset_strength`, `numpy`), Flutter/Dart (bestehendes `http`-Paket, kein neues Package).

## Global Constraints

- Keine neuen Abhängigkeiten (`librosa>=0.10.2` ist bereits Pflichtabhängigkeit, `.venv` hat 0.11.0 — `librosa.sequence.dtw` und `librosa.onset.onset_strength` sind vorhanden und bestätigt).
- Kein serverseitiges Caching/Persistieren von Audiodateien — jeder Aufruf von `/api/sync/align` bekommt Audio-Rohbytes frisch im Request (siehe `backend/api/state.py`: `MIDI_SESSIONS` hält nur das geparste `PrettyMIDI`-Objekt, nie Audiobytes).
- Frame-Rate durchgängig 100Hz (`frame_rate_hz=100.0`), identisch zu den bestehenden `analyze_pitch`/`track_pitch_curve`-Kurven, damit Hüllkurven-Index und Kurven-Frame ohne Resampling zusammenpassen.
- Nur der Mobile-Client (`mobile/`) bekommt die Chart-Anbindung in dieser Runde; `frontend/app.js` bleibt unverändert.
- Sobald `alignedSungCurve` befüllt ist, ersetzt sie die rohe Anzeige direkt — kein UI-Umschalter roh/ausgerichtet.
- Schlägt das Alignment fehl, bleibt die rohe (unausgerichtete) Kurve sichtbar statt eines Absturzes oder einer leeren Kurve.
- Deutsche Fehlermeldungen im bestehenden Stil (`HTTPException(status_code=..., detail="...")` backend-seitig, `ApiException`/`_messageOf` client-seitig).
- Keine HTTP-Layer-Tests (`TestClient`) einführen — im gesamten Repo bisher nirgends verwendet, alle Backend-Tests rufen Funktionen direkt auf; das gilt auch für die neue Route.

---

### Task 1: Audio-Decoding aus `pyin.py` in `backend/audio_io.py` extrahieren

**Files:**
- Create: `backend/audio_io.py`
- Modify: `backend/pitch_detection/pyin.py`
- Modify: `backend/pitch_detection/__init__.py`
- Test (bereits vorhanden, muss unverändert grün bleiben): `tests/test_pitch_detection.py`

**Interfaces:**
- Produces: `backend.audio_io.AudioDecodeError` (Exception), `backend.audio_io.load_audio_signal(audio_bytes: bytes, filename_hint: str = "upload.wav", max_seconds: float = 90.0) -> tuple[np.ndarray, int]` (Signal, Sample-Rate).
- Produces: `backend.pitch_detection.pitch_curve_from_signal(y: np.ndarray, sr: int, fmin: float = 65.0, fmax: float = 1050.0, frame_rate_hz: float = 100.0) -> list[dict]`.
- `backend.pitch_detection.analyze_pitch(...)` (bestehende Signatur, siehe `backend/pitch_detection/pyin.py:53-60`) bleibt öffentlich unverändert — reiner Wrapper um `load_audio_signal` + `pitch_curve_from_signal`.

Dies ist ein reiner, verhaltenserhaltender Refactor (keine neue Funktionalität) und die Voraussetzung für Task 4/5, die dieselbe dekodierte Signalform sowohl für die Tonhöhenkurve als auch für die Onset-Hüllkurve brauchen, ohne dieselben Audiobytes zweimal zu dekodieren.

- [ ] **Step 1: Baseline bestätigen**

Run: `.venv/bin/pytest tests/test_pitch_detection.py -v`
Expected: alle 5 Tests PASS (bestehender Stand vor dem Refactor).

- [ ] **Step 2: `backend/audio_io.py` anlegen**

```python
"""Gemeinsames Audio-Decoding fuer pitch_detection und sync (Phase 3).

Vorher steckte diese Logik ausschliesslich in pitch_detection/pyin.py; ausgelagert,
damit backend/sync dieselbe dekodierte Signalform bekommt, ohne dieselben
Audiobytes ein zweites Mal zu dekodieren.
"""

from __future__ import annotations

import os
import tempfile

import av
import librosa
import numpy as np

_ALLOWED_SUFFIXES = {".wav", ".mp3", ".flac", ".ogg", ".m4a", ".webm"}


class AudioDecodeError(Exception):
    """Audiodatei konnte nicht gelesen oder dekodiert werden."""


def _safe_suffix(filename_hint: str) -> str:
    suffix = os.path.splitext(filename_hint or "")[1].lower()
    return suffix if suffix in _ALLOWED_SUFFIXES else ".wav"


def _load_with_pyav(path: str) -> tuple[np.ndarray, int]:
    """Dekodiert Formate, die soundfile/audioread nicht lesen koennen (z.B. AAC-in-M4A,
    Opus-in-WebM von Mobile-/Browser-Recordern). PyAV bringt eigene ffmpeg-Libs im Wheel
    mit, braucht also anders als audioreads ffmpeg-Fallback keinen System-ffmpeg-Binary."""
    container = av.open(path)
    try:
        stream = container.streams.audio[0]
        sr = stream.codec_context.sample_rate
        resampler = av.AudioResampler(format="fltp", layout="mono", rate=sr)
        chunks = [
            rframe.to_ndarray()
            for frame in container.decode(stream)
            for rframe in resampler.resample(frame)
        ]
    finally:
        container.close()

    if not chunks:
        raise ValueError("PyAV hat keine Audio-Frames dekodiert.")
    y = np.concatenate(chunks, axis=1)[0].astype(np.float32)
    return y, sr


def load_audio_signal(
    audio_bytes: bytes,
    filename_hint: str = "upload.wav",
    max_seconds: float = 90.0,
) -> tuple[np.ndarray, int]:
    """Dekodiert Audio-Rohbytes zu (Samples, Sample-Rate), auf max_seconds gekappt.

    Die Audiodatei wird nur in einer temporaeren Datei zwischengehalten und danach
    sofort geloescht - keine dauerhafte Speicherung (siehe Datenschutz-Leitplanke).
    """
    if not audio_bytes:
        raise AudioDecodeError("Keine Audiodaten empfangen.")

    tmp_path: str | None = None
    try:
        with tempfile.NamedTemporaryFile(suffix=_safe_suffix(filename_hint), delete=False) as tmp:
            tmp.write(audio_bytes)
            tmp_path = tmp.name

        try:
            y, sr = librosa.load(tmp_path, sr=None, mono=True)
        except Exception:
            try:
                y, sr = _load_with_pyav(tmp_path)
            except Exception as exc:
                raise AudioDecodeError(
                    f"Audiodatei konnte nicht dekodiert werden (Format nicht unterstuetzt?): {exc}"
                ) from exc
    finally:
        if tmp_path and os.path.exists(tmp_path):
            os.remove(tmp_path)

    if y.size == 0:
        raise AudioDecodeError("Audiodatei enthaelt keine Samples.")

    max_samples = int(max_seconds * sr)
    if y.shape[0] > max_samples:
        y = y[:max_samples]

    return y, sr
```

- [ ] **Step 3: `backend/pitch_detection/pyin.py` umschreiben**

Ersetze den gesamten Dateiinhalt durch:

```python
"""Tonhoehenerkennung fuer die Gesangsaufnahme via librosa/pYIN (Phase 1).

Bewusst pYIN statt CREPE (siehe Plan-Annahmen): keine TensorFlow/Torch-Abhaengigkeit,
laeuft rein auf der CPU, fuer 20-60s-Ausschnitte ausreichend schnell. Das Modul ist
so gekapselt, dass ein Austausch gegen ein anderes Verfahren spaeter moeglich ist,
ohne die aufrufende API zu aendern.
"""

from __future__ import annotations

import librosa
import numpy as np

from backend.audio_io import AudioDecodeError, load_audio_signal


class PitchAnalysisError(Exception):
    """Aufnahme konnte nicht gelesen oder analysiert werden."""


def pitch_curve_from_signal(
    y: np.ndarray,
    sr: int,
    fmin: float = 65.0,
    fmax: float = 1050.0,
    frame_rate_hz: float = 100.0,
) -> list[dict]:
    """Liefert die Tonhoehe eines bereits dekodierten Signals als Zeitreihe:
    [{t, hz|None, voiced, confidence}]. hz ist None fuer unstimmhafte/stille
    Abschnitte (Pausen, Atmen, Konsonanten)."""
    hop_length = max(1, int(round(sr / frame_rate_hz)))
    f0, voiced_flag, voiced_prob = librosa.pyin(
        y, fmin=fmin, fmax=fmax, sr=sr, hop_length=hop_length,
    )
    times = librosa.times_like(f0, sr=sr, hop_length=hop_length)

    curve: list[dict] = []
    for t, hz, voiced, prob in zip(times, f0, voiced_flag, voiced_prob):
        is_voiced = bool(voiced) and not np.isnan(hz)
        curve.append({
            "t": round(float(t), 3),
            "hz": round(float(hz), 3) if is_voiced else None,
            "voiced": is_voiced,
            "confidence": round(float(prob), 3) if not np.isnan(prob) else 0.0,
        })
    return curve


def analyze_pitch(
    audio_bytes: bytes,
    filename_hint: str = "upload.wav",
    max_seconds: float = 90.0,
    fmin: float = 65.0,
    fmax: float = 1050.0,
    frame_rate_hz: float = 100.0,
) -> list[dict]:
    """Liefert die gesungene Tonhoehe als Zeitreihe: [{t, hz|None, voiced, confidence}].

    Dekodiert die Audiobytes (temporaer, wird sofort danach geloescht - siehe
    Datenschutz-Leitplanke) und delegiert die eigentliche Tonhoehenberechnung an
    pitch_curve_from_signal().
    """
    try:
        y, sr = load_audio_signal(audio_bytes, filename_hint, max_seconds)
    except AudioDecodeError as exc:
        raise PitchAnalysisError(str(exc)) from exc
    return pitch_curve_from_signal(y, sr, fmin=fmin, fmax=fmax, frame_rate_hz=frame_rate_hz)
```

- [ ] **Step 4: `backend/pitch_detection/__init__.py` erweitern**

```python
from .pyin import PitchAnalysisError, analyze_pitch, pitch_curve_from_signal

__all__ = ["analyze_pitch", "pitch_curve_from_signal", "PitchAnalysisError"]
```

- [ ] **Step 5: Bestehende Tests erneut laufen lassen**

Run: `.venv/bin/pytest tests/test_pitch_detection.py tests/test_e2e_phase1.py -v`
Expected: alle Tests weiterhin PASS, unverändertes Verhalten (reiner Refactor).

- [ ] **Step 6: Commit**

```bash
git add backend/audio_io.py backend/pitch_detection/pyin.py backend/pitch_detection/__init__.py
git commit -m "refactor: extract audio decoding into backend/audio_io.py"
```

---

### Task 2: Onset-Hüllkurven (`backend/sync/features.py`)

**Files:**
- Create: `backend/sync/features.py`
- Create: `tests/test_sync.py`

**Interfaces:**
- Consumes: nichts aus Task 1 direkt (arbeitet auf bereits dekodiertem `(y, sr)` bzw. auf einem `pretty_midi.PrettyMIDI`-Objekt aus `backend.midi_analysis.load_midi`).
- Produces: `backend.sync.features.onset_envelope_from_signal(y: np.ndarray, sr: int, frame_rate_hz: float = 100.0) -> list[float]`, `backend.sync.features.onset_envelope_from_midi_track(pm: pretty_midi.PrettyMIDI, track_index: int, frame_rate_hz: float = 100.0, decay_seconds: float = 0.06) -> list[float]`.

- [ ] **Step 1: Test schreiben (`tests/test_sync.py`, neu)**

```python
"""Tests fuer die DTW-Ausrichtung (Phase 3): Onset-Huellkurven + align_curves."""

from __future__ import annotations

import numpy as np
import pretty_midi
import pytest

from backend.sync import (
    align_curves,
    onset_envelope_from_midi_track,
    onset_envelope_from_signal,
)
from backend.midi_analysis import track_pitch_curve


def _two_note_pm() -> pretty_midi.PrettyMIDI:
    pm = pretty_midi.PrettyMIDI()
    inst = pretty_midi.Instrument(program=53, name="Vocal")
    inst.notes.append(pretty_midi.Note(velocity=90, pitch=60, start=0.0, end=1.0))
    inst.notes.append(pretty_midi.Note(velocity=90, pitch=64, start=1.0, end=2.0))
    pm.instruments.append(inst)
    return pm


def test_onset_envelope_from_midi_track_matches_curve_length():
    pm = _two_note_pm()
    curve = track_pitch_curve(pm, track_index=0, frame_rate_hz=100.0)
    env = onset_envelope_from_midi_track(pm, track_index=0, frame_rate_hz=100.0)
    assert len(env) == len(curve)


def test_onset_envelope_from_midi_track_peaks_at_note_onsets():
    env = onset_envelope_from_midi_track(
        _two_note_pm(), track_index=0, frame_rate_hz=100.0, decay_seconds=0.06,
    )
    # decay_frames = round(0.06 * 100) = 6 -> Kernel deckt Frames [onset, onset+6) ab.
    assert env[0] == pytest.approx(1.0)     # Onset Note 0 bei t=0.0s (Frame 0)
    assert env[100] == pytest.approx(1.0)   # Onset Note 1 bei t=1.0s (Frame 100)
    assert env[6] == pytest.approx(0.0)     # ausserhalb der Decay-Spanne von Note 0
    assert env[50] == pytest.approx(0.0)    # weit vor dem zweiten Onset


def test_onset_envelope_from_signal_is_nonnegative_and_has_plausible_length():
    sr = 22050
    duration = 1.0
    t = np.arange(int(duration * sr)) / sr
    y = (0.3 * np.sin(2 * np.pi * 440.0 * t)).astype(np.float32)

    env = onset_envelope_from_signal(y, sr, frame_rate_hz=100.0)

    assert len(env) > 90  # ~100 Frames fuer 1s bei 100Hz, kleine Abweichung durch librosa-Padding ok
    assert all(v >= 0 for v in env)
```

- [ ] **Step 2: Test laufen lassen, PASS für den mit `track_pitch_curve` vergleichenden Test erwarten, FAIL für die neuen Funktionen**

Run: `.venv/bin/pytest tests/test_sync.py -v`
Expected: FAIL mit `ImportError`/`ModuleNotFoundError` für `backend.sync.features` (Modul existiert noch nicht).

- [ ] **Step 3: `backend/sync/features.py` implementieren**

```python
"""Onset-/Energiehuellkurven fuer die DTW-Ausrichtung (Phase 3).

DTW laeuft bewusst NICHT auf der Rohtonhoehe (siehe PLAN.md, Abschnitt "Technisch
riskanteste Punkte"): ein DTW auf Rohtonhoehe wuerde genau dann versagen, wenn der
Nutzer die falsche Note singt - der Fall, den die spaetere Bewertung messen soll.
Stattdessen wird eine tonhoehen-unabhaengige Onset-Huellkurve verwendet.
"""

from __future__ import annotations

import librosa
import numpy as np
import pretty_midi


def onset_envelope_from_signal(
    y: np.ndarray, sr: int, frame_rate_hz: float = 100.0,
) -> list[float]:
    """Onset-Staerke aus echtem Audio (Gesangs- oder Referenzaufnahme).

    hop_length wird so gewaehlt, dass envelope[i] zeitlich zu Kurven-Frame i der
    pYIN-Tonhoehenkurve (pitch_curve_from_signal, gleiche frame_rate_hz) passt,
    ohne separaten Resampling-Schritt.
    """
    hop_length = max(1, int(round(sr / frame_rate_hz)))
    env = librosa.onset.onset_strength(y=y, sr=sr, hop_length=hop_length)
    return [float(v) for v in env]


def onset_envelope_from_midi_track(
    pm: pretty_midi.PrettyMIDI,
    track_index: int,
    frame_rate_hz: float = 100.0,
    decay_seconds: float = 0.06,
) -> list[float]:
    """Synthetischer Onset-Impuls-Zug aus den MIDI-Note-Startzeiten.

    Kein Audiosignal noetig (im Projekt existiert kein MIDI-Synthesizer) - die
    Onset-Zeiten sind aus den Noten bereits exakt bekannt. Frame-Anzahl/-Schritt
    sind identisch zu track_pitch_curve(), damit envelope[i] zu jener Kurve passt.
    """
    if track_index < 0 or track_index >= len(pm.instruments):
        raise ValueError(f"Ungueltiger Spurindex: {track_index}")

    inst = pm.instruments[track_index]
    if not inst.notes:
        return []

    end_time = max(n.end for n in inst.notes)
    step = 1.0 / frame_rate_hz
    n_frames = int(end_time / step) + 1

    decay_frames = max(1, int(round(decay_seconds * frame_rate_hz)))
    decay_kernel = np.exp(-3.0 * np.arange(decay_frames) / decay_frames)

    env = np.zeros(n_frames)
    for note in inst.notes:
        onset_frame = int(round(note.start / step))
        if onset_frame >= n_frames:
            continue
        span = min(decay_frames, n_frames - onset_frame)
        env[onset_frame:onset_frame + span] += decay_kernel[:span]

    return [float(v) for v in env]
```

- [ ] **Step 4: `backend/sync/__init__.py` aktualisieren**

```python
"""Synchronisation von Gesangsaufnahme und Zielmelodie (DTW, Phase 3)."""

from .features import onset_envelope_from_midi_track, onset_envelope_from_signal

__all__ = ["onset_envelope_from_midi_track", "onset_envelope_from_signal"]
```

(Das `align_curves`-Reexport kommt in Task 3 dazu — bis dahin schlägt der `from backend.sync import align_curves`-Import in `tests/test_sync.py` fehl; das ist erwartet, siehe nächster Schritt.)

- [ ] **Step 5: Tests laufen lassen — nur die Envelope-Tests müssen jetzt passen**

Run: `.venv/bin/pytest tests/test_sync.py -v -k "onset_envelope"`
Expected: alle drei `onset_envelope_*`-Tests PASS. (Der volle `pytest tests/test_sync.py` schlägt weiterhin am `align_curves`-Import fehl — wird in Task 3 behoben.)

- [ ] **Step 6: Commit**

```bash
git add backend/sync/features.py backend/sync/__init__.py tests/test_sync.py
git commit -m "feat: add onset-envelope extraction for DTW alignment"
```

---

### Task 3: DTW-Ausrichtung (`backend/sync/align.py`)

**Files:**
- Create: `backend/sync/align.py`
- Modify: `backend/sync/__init__.py`
- Modify: `tests/test_sync.py` (ergänzt um `align_curves`-Tests)

**Interfaces:**
- Consumes: `list[dict]`-Kurven im bestehenden Format (`{"t": float, ...}`), `list[float]`-Hüllkurven aus Task 2.
- Produces: `backend.sync.align.align_curves(target_curve: list[dict], target_envelope: list[float], sung_curve: list[dict], sung_envelope: list[float]) -> dict` mit Rückgabe `{"sung_curve": list[dict] (jeder Frame + "aligned_t": float | None), "target_duration": float}`.

- [ ] **Step 1: Tests ergänzen (an `tests/test_sync.py` anhängen)**

```python
from backend.sync import align_curves  # ergaenzt den bestehenden Import oben


def test_align_curves_recovers_early_onset_offset():
    step = 0.01  # 100Hz
    n = 200
    target_curve = [{"t": round(i * step, 3), "hz": 440.0, "midi_note": 69} for i in range(n)]
    target_envelope = [0.0] * n
    target_envelope[50] = 1.0  # Zielereignis bei t=0.50s

    sung_curve = [
        {"t": round(i * step, 3), "hz": 440.0, "voiced": True, "confidence": 0.9}
        for i in range(n)
    ]
    sung_envelope = [0.0] * n
    sung_envelope[35] = 1.0  # dasselbe Ereignis, aber 150ms (15 Frames) zu frueh (t=0.35s)

    result = align_curves(target_curve, target_envelope, sung_curve, sung_envelope)

    assert result["target_duration"] == target_curve[-1]["t"]
    aligned_t = result["sung_curve"][35]["aligned_t"]
    assert aligned_t is not None
    assert abs(aligned_t - 0.50) < 0.03


def test_align_curves_handles_empty_input_without_raising():
    result = align_curves([], [], [], [])
    assert result == {"sung_curve": [], "target_duration": 0.0}
```

- [ ] **Step 2: Tests laufen lassen, FAIL erwarten**

Run: `.venv/bin/pytest tests/test_sync.py -v -k "align_curves"`
Expected: FAIL mit `ImportError` für `align_curves` (existiert noch nicht in `backend/sync/align.py`/`__init__.py`).

- [ ] **Step 3: `backend/sync/align.py` implementieren**

```python
"""DTW-Ausrichtung der gesungenen Kurve auf die Zielkurve (Phase 3)."""

from __future__ import annotations

import librosa
import numpy as np


def _zscore(values: list[float]) -> np.ndarray:
    arr = np.asarray(values, dtype=np.float64)
    if arr.size == 0:
        return arr
    std = arr.std()
    if std < 1e-9:
        return arr - arr.mean()
    return (arr - arr.mean()) / std


def align_curves(
    target_curve: list[dict],
    target_envelope: list[float],
    sung_curve: list[dict],
    sung_envelope: list[float],
) -> dict:
    """DTW-alignt die gesungene Onset-Huellkurve auf die Ziel-Huellkurve.

    Liefert sung_curve mit einem zusaetzlichen Feld 'aligned_t' pro Frame (die
    Zielzeit, auf die dieser Gesangs-Frame laut Warping-Pfad faellt, oder None
    wenn kein Warping-Pfad-Eintrag fuer diesen Frame existiert) sowie
    target_duration fuer die Client-x-Achsenskalierung.
    """
    if not target_curve or not sung_curve or not target_envelope or not sung_envelope:
        aligned = [{**frame, "aligned_t": None} for frame in sung_curve]
        return {
            "sung_curve": aligned,
            "target_duration": target_curve[-1]["t"] if target_curve else 0.0,
        }

    x = _zscore(target_envelope)[None, :]
    y = _zscore(sung_envelope)[None, :]
    _, wp = librosa.sequence.dtw(X=x, Y=y, metric="euclidean", subseq=False, backtrack=True)

    # wp laeuft in absteigender Reihenfolge von (len(target)-1, len(sung)-1) nach (0, 0);
    # reversed(...) macht daraus die chronologische Reihenfolge. Bei mehreren
    # Ziel-Frames fuer denselben Gesangs-Frame gewinnt der chronologisch letzte Treffer.
    n_target = len(target_curve)
    n_sung = len(sung_curve)
    j_to_target_t: dict[int, float] = {}
    for i, j in reversed(wp):
        if i < n_target and j < n_sung:
            j_to_target_t[int(j)] = target_curve[int(i)]["t"]

    aligned: list[dict] = []
    last_known: float | None = None
    for idx, frame in enumerate(sung_curve):
        t = j_to_target_t.get(idx, last_known)
        if t is not None:
            last_known = t
        aligned.append({**frame, "aligned_t": t})

    return {
        "sung_curve": aligned,
        "target_duration": target_curve[-1]["t"],
    }
```

- [ ] **Step 4: `backend/sync/__init__.py` erweitern**

```python
"""Synchronisation von Gesangsaufnahme und Zielmelodie (DTW, Phase 3)."""

from .align import align_curves
from .features import onset_envelope_from_midi_track, onset_envelope_from_signal

__all__ = ["align_curves", "onset_envelope_from_midi_track", "onset_envelope_from_signal"]
```

- [ ] **Step 5: Alle Sync-Tests laufen lassen**

Run: `.venv/bin/pytest tests/test_sync.py -v`
Expected: alle 5 Tests PASS (3 aus Task 2, 2 aus diesem Task).

- [ ] **Step 6: Commit**

```bash
git add backend/sync/align.py backend/sync/__init__.py tests/test_sync.py
git commit -m "feat: add DTW curve alignment (backend/sync/align.py)"
```

---

### Task 4: End-to-End-Validierung mit der bestehenden Fixture

**Files:**
- Create: `tests/test_e2e_phase3.py`

**Interfaces:**
- Consumes: `backend.audio_io.load_audio_signal` (Task 1), `backend.pitch_detection.pitch_curve_from_signal` (Task 1), `backend.midi_analysis.track_pitch_curve`/`load_midi` (bestehend), `backend.sync.{align_curves, onset_envelope_from_midi_track, onset_envelope_from_signal}` (Task 2+3), `tests.fixtures.generate_fixtures.generate` (bestehend).
- Produces: nichts (reiner Validierungstest, keine neue Produktionslogik).

Dieser Test ist die eigentliche fachliche Abnahme des Algorithmus: er bestätigt anhand der schon vorhandenen synthetischen Testaufnahme (`tests/fixtures/generate_fixtures.py`, 5-Noten-Melodie C-E-G-E-C), dass die absichtlich 150ms zu früh gesungene Note 2 (G4) korrekt zurückgemappt wird, während unveränderte Noten (0 und 4) nahe ihrer Rohzeit bleiben.

- [ ] **Step 1: Test schreiben**

```python
"""End-to-End-Test fuer die Phase-3-DTW-Ausrichtung.

Nutzt dieselben synthetischen Fixtures wie test_e2e_phase1.py. Kernaussage: die
absichtlich 150ms zu frueh gesungene Note 2 (siehe fixtures/generate_fixtures.py,
MELODY-Kommentare) wird durch align_curves() korrekt auf die Zielzeit zurueckgemappt,
waehrend unveraenderte Noten (0 und 4) nahe ihrer eigenen Rohzeit bleiben.
"""

from __future__ import annotations

from pathlib import Path

from backend.audio_io import load_audio_signal
from backend.midi_analysis import load_midi, track_pitch_curve
from backend.pitch_detection import pitch_curve_from_signal
from backend.sync import align_curves, onset_envelope_from_midi_track, onset_envelope_from_signal

from .fixtures.generate_fixtures import generate

FIXTURES_DIR = Path(__file__).resolve().parent / "fixtures"


def _closest_aligned_delta(aligned_curve: list[dict], target_t: float) -> float:
    frame = min(aligned_curve, key=lambda p: abs(p["t"] - target_t))
    assert frame["aligned_t"] is not None, f"kein Alignment fuer Frame bei t={frame['t']}"
    return frame["aligned_t"] - frame["t"]


def test_dtw_alignment_recovers_early_onset_and_leaves_correct_notes_unshifted():
    midi_path, wav_path = generate(FIXTURES_DIR)

    pm = load_midi(midi_path.read_bytes())
    target_curve = track_pitch_curve(pm, track_index=0, frame_rate_hz=100.0)
    target_envelope = onset_envelope_from_midi_track(pm, track_index=0, frame_rate_hz=100.0)

    y, sr = load_audio_signal(wav_path.read_bytes(), filename_hint="test_vocal.wav")
    sung_curve = pitch_curve_from_signal(y, sr, frame_rate_hz=100.0)
    sung_envelope = onset_envelope_from_signal(y, sr, frame_rate_hz=100.0)

    result = align_curves(target_curve, target_envelope, sung_curve, sung_envelope)
    aligned_curve = result["sung_curve"]

    # Note 2 (G4) wird 150ms zu frueh gesungen (t~1.85s statt 2.0s) - das Alignment
    # muss diesen Frame um ~+0.15s in Richtung Zielzeit verschieben.
    delta_early_note = _closest_aligned_delta(aligned_curve, target_t=1.85)
    assert 0.08 <= delta_early_note <= 0.22, (
        f"erwartete ~+0.15s Korrektur fuer die zu frueh gesungene Note, war {delta_early_note:.3f}s"
    )

    # Note 0 und Note 4 werden korrekt (unverschoben) gesungen - keine grosse Korrektur.
    delta_note0 = _closest_aligned_delta(aligned_curve, target_t=0.5)
    delta_note4 = _closest_aligned_delta(aligned_curve, target_t=4.5)
    assert abs(delta_note0) < 0.08, f"unveraenderte Note 0 wurde faelschlich verschoben: {delta_note0:.3f}s"
    assert abs(delta_note4) < 0.08, f"unveraenderte Note 4 wurde faelschlich verschoben: {delta_note4:.3f}s"


if __name__ == "__main__":
    test_dtw_alignment_recovers_early_onset_and_leaves_correct_notes_unshifted()
    print("Phase-3-DTW-Alignment-Test erfolgreich.")
```

- [ ] **Step 2: Test ausführen**

Run: `.venv/bin/pytest tests/test_e2e_phase3.py -v`

Erwartung: PASS. Da dieser Test auf echten, per `librosa.pyin`/`librosa.onset.onset_strength` verarbeiteten synthetischen Audiodaten beruht (nicht auf handgebauten Zahlenreihen wie in Task 3), ist ein Fehlschlag beim ersten Lauf möglich. **Falls FAIL:** Füge vor den Assertions temporär `print([(p["t"], p["aligned_t"]) for p in aligned_curve])` ein, um die tatsächlichen `aligned_t`-Werte rund um t=1.85s/0.5s/4.5s zu sehen, und passe die Toleranzbänder (`0.08`/`0.22`) bzw. `decay_seconds` in `onset_envelope_from_midi_track` (Task 2) auf Basis der beobachteten Werte an — die Assertions müssen dabei weiterhin trennscharf zwischen der verschobenen und den unveränderten Noten unterscheiden, nicht einfach aufgeweitet werden, bis der Test zufällig grün ist. Entferne den Debug-`print` wieder, sobald die Toleranzen stimmen.

- [ ] **Step 3: Commit**

```bash
git add tests/test_e2e_phase3.py
git commit -m "test: add Phase 3 end-to-end DTW alignment validation"
```

---

### Task 5: Backend-Endpunkt `POST /api/sync/align`

**Files:**
- Modify: `backend/api/routes.py`

**Interfaces:**
- Consumes: `backend.audio_io.{AudioDecodeError, load_audio_signal}` (Task 1), `backend.pitch_detection.pitch_curve_from_signal` (Task 1), `backend.sync.{align_curves, onset_envelope_from_midi_track, onset_envelope_from_signal}` (Task 2+3), `backend.midi_analysis.track_pitch_curve` (bestehend), `backend.api.state.MIDI_SESSIONS` (bestehend).
- Produces: Route `POST /api/sync/align`, Response-Form `{"target_curve": list[dict], "sung_curve": list[dict] (mit aligned_t), "target_duration": float}`.

Kein automatisierter Test für diesen Task (siehe Global Constraints — im gesamten Repo gibt es keine `TestClient`-Tests; die Kernlogik ist bereits über Task 1-4 abgedeckt). Verifikation erfolgt manuell über den laufenden Server.

- [ ] **Step 1: Imports in `backend/api/routes.py` ergänzen**

Am Anfang der Datei, nach den bestehenden Imports (`backend/api/routes.py:12-19`):

```python
from fastapi import APIRouter, Depends, File, Form, HTTPException, Request, UploadFile

from backend.audio_io import AudioDecodeError, load_audio_signal
from backend.config import MAX_AUDIO_SECONDS, PITCH_FMAX_HZ, PITCH_FMIN_HZ
from backend.midi_analysis import list_track_candidates, load_midi, track_pitch_curve
from backend.pitch_detection import PitchAnalysisError, analyze_pitch, pitch_curve_from_signal
from backend.sync import align_curves, onset_envelope_from_midi_track, onset_envelope_from_signal

from .rate_limit import enforce_upload_rate_limit
from .state import MIDI_SESSIONS
```

(Ersetzt die bestehende `from fastapi import ...`-Zeile um `Form`, sowie die bestehenden `from backend...`-Importzeilen um die neuen Module/Namen.)

- [ ] **Step 2: Neue Route am Dateiende ergänzen (nach `analyze_audio`, `backend/api/routes.py:89-107`)**

```python
@router.post("/sync/align", dependencies=[Depends(enforce_upload_rate_limit)])
def sync_align(
    request: Request,
    sung_audio: UploadFile = File(...),
    session_id: str | None = Form(None),
    track_index: int | None = Form(None),
    transpose: int = Form(0),
    reference_audio: UploadFile | None = File(None),
) -> dict:
    _reject_oversized_content_length(request, MAX_AUDIO_UPLOAD_BYTES)

    sung_bytes = sung_audio.file.read()
    if len(sung_bytes) > MAX_AUDIO_UPLOAD_BYTES:
        raise HTTPException(status_code=413, detail="Audiodatei ist unerwartet gross.")

    try:
        y_sung, sr_sung = load_audio_signal(sung_bytes, sung_audio.filename or "sung.wav", MAX_AUDIO_SECONDS)
    except AudioDecodeError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    sung_curve = pitch_curve_from_signal(y_sung, sr_sung, fmin=PITCH_FMIN_HZ, fmax=PITCH_FMAX_HZ)
    sung_envelope = onset_envelope_from_signal(y_sung, sr_sung)

    if reference_audio is not None:
        ref_bytes = reference_audio.file.read()
        if len(ref_bytes) > MAX_AUDIO_UPLOAD_BYTES:
            raise HTTPException(status_code=413, detail="Referenz-Audiodatei ist unerwartet gross.")
        try:
            y_ref, sr_ref = load_audio_signal(
                ref_bytes, reference_audio.filename or "reference.wav", MAX_AUDIO_SECONDS,
            )
        except AudioDecodeError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        target_curve = pitch_curve_from_signal(y_ref, sr_ref, fmin=PITCH_FMIN_HZ, fmax=PITCH_FMAX_HZ)
        target_envelope = onset_envelope_from_signal(y_ref, sr_ref)
    elif session_id is not None and track_index is not None:
        pm = MIDI_SESSIONS.get(session_id)
        if pm is None:
            raise HTTPException(
                status_code=404,
                detail="MIDI-Session nicht gefunden oder abgelaufen - bitte Datei erneut hochladen.",
            )
        try:
            target_curve = track_pitch_curve(pm, track_index, transpose_semitones=transpose)
            target_envelope = onset_envelope_from_midi_track(pm, track_index)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
    else:
        raise HTTPException(
            status_code=400,
            detail="Entweder session_id und track_index oder reference_audio angeben.",
        )

    result = align_curves(target_curve, target_envelope, sung_curve, sung_envelope)
    return {"target_curve": target_curve, **result}
```

- [ ] **Step 3: Bestehende Tests erneut laufen lassen (Regressionsschutz)**

Run: `.venv/bin/pytest tests/ -v`
Expected: alle Tests weiterhin PASS (Task 1-4 Tests + `test_midi_analysis.py`).

- [ ] **Step 4: Manuelle Verifikation über den laufenden Server**

```bash
.venv/bin/python run.py &
sleep 2

SESSION_ID=$(curl -s -F "file=@tests/fixtures/test_reference.mid" http://127.0.0.1:8000/api/midi/upload | python3 -c "import json,sys; print(json.load(sys.stdin)['session_id'])")

curl -s -F "sung_audio=@tests/fixtures/test_vocal.wav" \
     -F "session_id=$SESSION_ID" -F "track_index=0" \
     http://127.0.0.1:8000/api/sync/align | python3 -m json.tool | head -40
```

Erwartung: HTTP 200, JSON mit `target_curve`, `sung_curve` (jeder Eintrag mit `aligned_t`) und `target_duration`. Server danach beenden (`kill %1` bzw. den Hintergrundprozess stoppen).

- [ ] **Step 5: Commit**

```bash
git add backend/api/routes.py
git commit -m "feat: add POST /api/sync/align endpoint"
```

---

### Task 6: Mobile API-Layer (`SungPoint`, `ApiClient`, `SyncApi`)

**Files:**
- Modify: `mobile/lib/models/sung_point.dart`
- Modify: `mobile/lib/api/api_client.dart`
- Create: `mobile/lib/api/sync_api.dart`

**Interfaces:**
- Produces: `SungPoint.alignedT` (nullable `double`, neues Feld), `ApiClient.postMultipart(...)` erweitert um optionale `fields`, `secondFieldName`, `secondBytes`, `secondFilename` (Rückwärtskompatibel — bestehende Aufrufe aus `MidiApi`/`AudioApi` bleiben unverändert gültig), `SyncApi.alignWithMidi(...)`, `SyncApi.alignWithReference(...)` (beide `Future<List<SungPoint>>`).

Kein eigener Widget-/Unit-Test für diesen Task (siehe bestehende Konvention: die API-Layer-Klassen `MidiApi`/`AudioApi` haben ebenfalls keine direkten Tests) — Abdeckung erfolgt transitiv über die `session_state_test.dart`-Erweiterungen in Task 7.

- [ ] **Step 1: `mobile/lib/models/sung_point.dart` erweitern**

Ersetze den Dateiinhalt durch:

```dart
/// Ein Punkt der gesungenen Pitch-Kurve, wie sie analyze_pitch() in
/// backend/pitch_detection/pyin.py liefert. hz ist null bei unstimmhaften/stillen
/// Abschnitten (Pausen, Atmen, Konsonanten) - dort gilt voiced == false.
///
/// alignedT ist null, bis /api/sync/align erfolgreich war - dann die per DTW
/// ermittelte Zielzeit dieses Frames (siehe backend/sync/align.py).
class SungPoint {
  final double t;
  final double? hz;
  final bool voiced;
  final double confidence;
  final double? alignedT;

  const SungPoint({
    required this.t,
    required this.hz,
    required this.voiced,
    required this.confidence,
    this.alignedT,
  });

  factory SungPoint.fromJson(Map<String, dynamic> json) {
    return SungPoint(
      t: (json['t'] as num).toDouble(),
      hz: (json['hz'] as num?)?.toDouble(),
      voiced: json['voiced'] as bool,
      confidence: (json['confidence'] as num).toDouble(),
      alignedT: (json['aligned_t'] as num?)?.toDouble(),
    );
  }
}
```

- [ ] **Step 2: `mobile/lib/api/api_client.dart` — `postMultipart` erweitern**

Ersetze die bestehende `postMultipart`-Methode (`mobile/lib/api/api_client.dart:59-70`) durch:

```dart
  Future<Map<String, dynamic>> postMultipart(
    String path, {
    required String fieldName,
    required Uint8List bytes,
    required String filename,
    Map<String, String>? fields,
    String? secondFieldName,
    Uint8List? secondBytes,
    String? secondFilename,
  }) async {
    final request = http.MultipartRequest('POST', _uri(path));
    request.files.add(http.MultipartFile.fromBytes(fieldName, bytes, filename: filename));
    if (fields != null) {
      request.fields.addAll(fields);
    }
    if (secondFieldName != null && secondBytes != null) {
      request.files.add(http.MultipartFile.fromBytes(
        secondFieldName,
        secondBytes,
        filename: secondFilename ?? 'file',
      ));
    }
    final streamedResponse = await _http.send(request);
    final response = await http.Response.fromStream(streamedResponse);
    return _decode(response);
  }
```

- [ ] **Step 3: `mobile/lib/api/sync_api.dart` anlegen**

```dart
import 'dart:typed_data';

import '../models/sung_point.dart';
import 'api_client.dart';

/// Ruft POST /api/sync/align auf (backend/api/routes.py::sync_align) und liefert
/// die gesungene Kurve mit aligned_t pro Frame zurueck. target_curve/target_duration
/// aus der Antwort werden bewusst nicht geparst - der Client hat die Zielkurve
/// bereits unabhaengig ueber MidiApi/analyzeReference geladen.
class SyncApi {
  final ApiClient _client;

  SyncApi(this._client);

  Future<List<SungPoint>> alignWithMidi(
    Uint8List sungBytes,
    String sungFilename, {
    required String sessionId,
    required int trackIndex,
    int transpose = 0,
  }) async {
    final json = await _client.postMultipart(
      '/api/sync/align',
      fieldName: 'sung_audio',
      bytes: sungBytes,
      filename: sungFilename,
      fields: {
        'session_id': sessionId,
        'track_index': trackIndex.toString(),
        'transpose': transpose.toString(),
      },
    );
    return _parseSungCurve(json);
  }

  Future<List<SungPoint>> alignWithReference(
    Uint8List sungBytes,
    String sungFilename,
    Uint8List referenceBytes,
    String referenceFilename,
  ) async {
    final json = await _client.postMultipart(
      '/api/sync/align',
      fieldName: 'sung_audio',
      bytes: sungBytes,
      filename: sungFilename,
      secondFieldName: 'reference_audio',
      secondBytes: referenceBytes,
      secondFilename: referenceFilename,
    );
    return _parseSungCurve(json);
  }

  List<SungPoint> _parseSungCurve(Map<String, dynamic> json) {
    final curve = (json['sung_curve'] as List).cast<Map<String, dynamic>>();
    return curve.map(SungPoint.fromJson).toList();
  }
}
```

- [ ] **Step 4: Statische Analyse laufen lassen**

Run: `cd mobile && flutter analyze`
Expected: keine neuen Fehler/Warnungen zu den drei geänderten/neuen Dateien.

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/models/sung_point.dart mobile/lib/api/api_client.dart mobile/lib/api/sync_api.dart
git commit -m "feat: add SyncApi and aligned_t support to mobile API layer"
```

---

### Task 7: `SessionState` — automatisches Alignment nach der Aufnahme

**Files:**
- Modify: `mobile/lib/state/session_state.dart`
- Modify: `mobile/test/session_state_test.dart`

**Interfaces:**
- Consumes: `SyncApi.alignWithMidi`/`alignWithReference` (Task 6).
- Produces: `SessionState.alignedSungCurve` (`List<SungPoint>`), `SessionState.alignStatus`/`alignMessage`, `SessionState.displayedSungCurve` (Getter, `List<SungPoint>`), `SessionState.align()` (`Future<void>`, wird intern von `analyzeAudio()` aufgerufen).

- [ ] **Step 1: `_FakeApiClient` in `mobile/test/session_state_test.dart` erweitern + neue Tests schreiben**

Ersetze den Kopf der Datei (Imports + `_FakeApiClient` + `_buildSession`, `mobile/test/session_state_test.dart:1-33`) durch:

```dart
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:singing_feedback_mobile/api/api_client.dart';
import 'package:singing_feedback_mobile/api/audio_api.dart';
import 'package:singing_feedback_mobile/api/midi_api.dart';
import 'package:singing_feedback_mobile/api/sync_api.dart';
import 'package:singing_feedback_mobile/models/target_point.dart';
import 'package:singing_feedback_mobile/state/session_state.dart';

class _FakeApiClient extends ApiClient {
  _FakeApiClient() : super(baseUrl: 'http://fake.local');

  @override
  Future<Map<String, dynamic>> postMultipart(
    String path, {
    required String fieldName,
    required Uint8List bytes,
    required String filename,
    Map<String, String>? fields,
    String? secondFieldName,
    Uint8List? secondBytes,
    String? secondFilename,
  }) async {
    if (path == '/api/sync/align') {
      return {
        'target_curve': [
          {'t': 0.0, 'hz': 440.0, 'midi_note': 69},
        ],
        'sung_curve': [
          {'t': 0.0, 'hz': 440.0, 'voiced': true, 'confidence': 0.9, 'aligned_t': 0.05},
          {'t': 0.01, 'hz': null, 'voiced': false, 'confidence': 0.0, 'aligned_t': null},
        ],
        'target_duration': 1.0,
      };
    }
    return {
      'curve': [
        {'t': 0.0, 'hz': 440.0, 'voiced': true, 'confidence': 0.9},
        {'t': 0.01, 'hz': null, 'voiced': false, 'confidence': 0.0},
      ],
    };
  }
}

SessionState _buildSession() {
  final client = _FakeApiClient();
  return SessionState(
    midiApi: MidiApi(client),
    audioApi: AudioApi(client),
    syncApi: SyncApi(client),
  );
}
```

Füge am Ende von `main()` (vor der abschließenden `}`, nach der letzten bestehenden Test-Funktion in `mobile/test/session_state_test.dart:141-152`) diese neuen Tests hinzu:

```dart
  test('analyzeAudio loest automatisch align() aus und befuellt alignedSungCurve (MIDI-Modus)',
      () async {
    final session = _buildSession();
    session.midiSessionId = 'sess-1';
    session.selectedTrackIndex = 0;

    await session.analyzeAudio(Uint8List.fromList([1, 2, 3]), 'gesang.wav');

    expect(session.alignStatus, LoadStatus.ok);
    expect(session.alignedSungCurve.length, 2);
    expect(session.alignedSungCurve[0].alignedT, closeTo(0.05, 0.001));
    expect(session.displayedSungCurve, session.alignedSungCurve);
  });

  test('analyzeAudio loest align() im Referenz-Modus mit reference_audio aus', () async {
    final session = _buildSession();
    session.setReferenceSource(ReferenceSource.recording);
    await session.analyzeReference(Uint8List.fromList([9, 9, 9]), 'referenz.wav');

    await session.analyzeAudio(Uint8List.fromList([1, 2, 3]), 'gesang.wav');

    expect(session.alignStatus, LoadStatus.ok);
    expect(session.alignedSungCurve.length, 2);
  });

  test('displayedSungCurve faellt ohne Alignment auf die rohe sungCurve zurueck', () {
    final session = _buildSession();
    expect(session.alignedSungCurve, isEmpty);
    expect(session.displayedSungCurve, session.sungCurve);
  });

  test('align() schlaegt im MIDI-Modus ohne ausgewaehlte Spur fehl, ohne sungCurve zu veraendern',
      () async {
    final session = _buildSession();
    // Kein midiSessionId/selectedTrackIndex gesetzt.
    await session.analyzeAudio(Uint8List.fromList([1, 2, 3]), 'gesang.wav');

    expect(session.audioStatus, LoadStatus.ok);
    expect(session.alignStatus, LoadStatus.error);
    expect(session.alignedSungCurve, isEmpty);
    expect(session.displayedSungCurve, session.sungCurve);
  });

  test('setReferenceSource setzt alignedSungCurve/alignStatus zurueck', () async {
    final session = _buildSession();
    session.midiSessionId = 'sess-1';
    session.selectedTrackIndex = 0;
    await session.analyzeAudio(Uint8List.fromList([1, 2, 3]), 'gesang.wav');
    expect(session.alignedSungCurve, isNotEmpty);

    session.setReferenceSource(ReferenceSource.recording);

    expect(session.alignedSungCurve, isEmpty);
    expect(session.alignStatus, LoadStatus.idle);
  });
```

- [ ] **Step 2: Tests laufen lassen, FAIL erwarten**

Run: `cd mobile && flutter test test/session_state_test.dart`
Expected: FAIL — `SessionState` kennt weder den `syncApi`-Konstruktorparameter noch `alignedSungCurve`/`alignStatus`/`displayedSungCurve`/`align()` (Compile-Fehler).

- [ ] **Step 3: `mobile/lib/state/session_state.dart` erweitern**

Import ergänzen (nach `import '../api/midi_api.dart';`, `mobile/lib/state/session_state.dart:7`):

```dart
import '../api/sync_api.dart';
```

Konstruktor + Felder (`mobile/lib/state/session_state.dart:18-42`) ersetzen durch:

```dart
class SessionState extends ChangeNotifier {
  final MidiApi midiApi;
  final AudioApi audioApi;
  final SyncApi syncApi;

  SessionState({required this.midiApi, required this.audioApi, required this.syncApi});

  String? midiSessionId;
  List<TrackCandidate> candidates = [];
  int? selectedTrackIndex;
  int transposeSemitones = 0;
  int referenceTransposeSemitones = 0;
  List<TargetPoint> targetCurve = [];
  List<SungPoint> sungCurve = [];

  LoadStatus midiStatus = LoadStatus.idle;
  String midiMessage = '';
  LoadStatus audioStatus = LoadStatus.idle;
  String audioMessage = '';

  ReferenceSource referenceSource = ReferenceSource.midi;
  List<SungPoint> referenceRawCurve = [];
  LoadStatus referenceStatus = LoadStatus.idle;
  String referenceMessage = '';
  Uint8List? referenceAudioBytes;
  Uint8List? sungAudioBytes;

  List<SungPoint> alignedSungCurve = [];
  LoadStatus alignStatus = LoadStatus.idle;
  String alignMessage = '';

  /// Die fuer den Chart zu zeichnende gesungene Kurve: ausgerichtet, sobald ein
  /// Alignment vorliegt, sonst (noch nicht fertig oder fehlgeschlagen) die rohe
  /// Kurve - kein Absturz/leerer Chart bei einem Alignment-Fehler.
  List<SungPoint> get displayedSungCurve =>
      alignedSungCurve.isNotEmpty ? alignedSungCurve : sungCurve;
```

`audioSectionEnabled`/`displayedTranspose`/`displayedTargetCurve` bleiben unverändert (`mobile/lib/state/session_state.dart:44-66`).

`analyzeAudio` (`mobile/lib/state/session_state.dart:132-146`) ersetzen durch:

```dart
  Future<void> analyzeAudio(Uint8List bytes, String filename) async {
    sungAudioBytes = bytes;
    audioStatus = LoadStatus.loading;
    audioMessage = 'Analysiere Tonhöhe der Aufnahme…';
    alignedSungCurve = [];
    alignStatus = LoadStatus.idle;
    alignMessage = '';
    notifyListeners();
    try {
      sungCurve = await audioApi.analyzeAudio(bytes, filename);
      audioStatus = LoadStatus.ok;
      audioMessage = 'Analyse fertig.';
      notifyListeners();
      await align();
      return;
    } catch (e) {
      audioStatus = LoadStatus.error;
      audioMessage = 'Fehler: ${_messageOf(e)}';
    }
    notifyListeners();
  }

  /// Richtet die gesungene Kurve per DTW auf die Zielmelodie aus (MIDI oder
  /// Referenzaufnahme, je nach referenceSource). Wird automatisch am Ende einer
  /// erfolgreichen analyzeAudio() angestossen - kein manueller Button. Transpose-
  /// Aenderungen loesen bewusst KEIN erneutes Alignment aus: onset_envelope_from_
  /// midi_track (backend/sync/features.py) haengt nicht von transpose ab, das
  /// Warping-Ergebnis bleibt bei einer reinen Tonhoehenverschiebung gueltig.
  Future<void> align() async {
    if (sungAudioBytes == null) return;
    alignStatus = LoadStatus.loading;
    alignMessage = 'Richte Aufnahme zeitlich aus…';
    notifyListeners();
    try {
      if (referenceSource == ReferenceSource.midi) {
        if (midiSessionId == null || selectedTrackIndex == null) {
          throw StateError('Keine MIDI-Spur ausgewählt.');
        }
        alignedSungCurve = await syncApi.alignWithMidi(
          sungAudioBytes!,
          'gesang.wav',
          sessionId: midiSessionId!,
          trackIndex: selectedTrackIndex!,
          transpose: transposeSemitones,
        );
      } else {
        if (referenceAudioBytes == null) {
          throw StateError('Keine Referenzaufnahme vorhanden.');
        }
        alignedSungCurve = await syncApi.alignWithReference(
          sungAudioBytes!,
          'gesang.wav',
          referenceAudioBytes!,
          'referenz.wav',
        );
      }
      alignStatus = LoadStatus.ok;
      alignMessage = 'Ausrichtung fertig.';
    } catch (e) {
      alignStatus = LoadStatus.error;
      alignMessage = 'Ausrichtung fehlgeschlagen: ${_messageOf(e)}';
      // alignedSungCurve bleibt leer - displayedSungCurve faellt automatisch auf
      // die rohe sungCurve zurueck (siehe Getter oben).
    }
    notifyListeners();
  }
```

`setReferenceSource` (`mobile/lib/state/session_state.dart:165-173`) ersetzen durch:

```dart
  void setReferenceSource(ReferenceSource source) {
    if (source == referenceSource) return;
    referenceSource = source;
    sungCurve = [];
    sungAudioBytes = null;
    audioStatus = LoadStatus.idle;
    audioMessage = '';
    alignedSungCurve = [];
    alignStatus = LoadStatus.idle;
    alignMessage = '';
    notifyListeners();
  }
```

`_resetAudioSection` (`mobile/lib/state/session_state.dart:175-182`) ersetzen durch:

```dart
  void _resetAudioSection() {
    selectedTrackIndex = null;
    targetCurve = [];
    sungCurve = [];
    sungAudioBytes = null;
    audioStatus = LoadStatus.idle;
    audioMessage = '';
    alignedSungCurve = [];
    alignStatus = LoadStatus.idle;
    alignMessage = '';
  }
```

- [ ] **Step 4: Tests laufen lassen**

Run: `cd mobile && flutter test test/session_state_test.dart`
Expected: alle Tests (bestehende + 5 neue) PASS.

- [ ] **Step 5: Vollen Mobile-Testlauf zur Regressionsprüfung**

Run: `cd mobile && flutter test`
Expected: alle Tests PASS (inkl. `playback_button_test.dart`, `playback_button_layout_test.dart`, `widget_test.dart`, unverändert).

- [ ] **Step 6: Commit**

```bash
git add mobile/lib/state/session_state.dart mobile/test/session_state_test.dart
git commit -m "feat: auto-trigger DTW alignment after recording analysis"
```

---

### Task 8: Chart & Wiring (`PitchChart`, `HomeScreen`, `main.dart`)

**Files:**
- Modify: `mobile/lib/widgets/pitch_chart.dart`
- Modify: `mobile/lib/screens/home_screen.dart`
- Modify: `mobile/lib/main.dart`

**Interfaces:**
- Consumes: `SessionState.displayedSungCurve` (Task 7), `SungPoint.alignedT` (Task 6).
- Produces: nichts Neues nach außen — reine Verdrahtung, kein neues Widget-API.

Kein neuer automatisierter Test (siehe bestehende Konvention: keine Pixel-/Golden-Tests für `PitchChart` im gesamten Repo). Verifikation über `flutter analyze` + manuellen App-Lauf.

- [ ] **Step 1: `mobile/lib/widgets/pitch_chart.dart` — `_PitchChartPainter.paint()` anpassen**

Füge nach der Klassenkonstante `_labelColor` (`mobile/lib/widgets/pitch_chart.dart:61`) eine kleine Hilfsfunktion hinzu:

```dart
  static double _sungDisplayT(SungPoint p) => p.alignedT ?? p.t;
```

Ersetze die `maxTime`-Berechnung (`mobile/lib/widgets/pitch_chart.dart:84-88`):

```dart
    final maxTime = [
      targetCurve.isNotEmpty ? targetCurve.last.t : 0.0,
      sungCurve.isNotEmpty ? _sungDisplayT(sungCurve.last) : 0.0,
      1.0,
    ].reduce(math.max);
```

Ersetze den zweiten `_drawCurve`-Aufruf (`mobile/lib/widgets/pitch_chart.dart:129-135`):

```dart
    _drawCurve(
      canvas,
      sungCurve.map((p) => _CurvePoint(_sungDisplayT(p), p.voiced ? p.hz : null)).toList(),
      xForT,
      yForNote,
      _sungColor,
    );
```

- [ ] **Step 2: `mobile/lib/screens/home_screen.dart` — `PitchChart`-Aufruf anpassen**

Ändere in der `PitchChart(...)`-Instanziierung (`mobile/lib/screens/home_screen.dart:123-126`):

```dart
              child: PitchChart(
                targetCurve: session.displayedTargetCurve,
                sungCurve: session.displayedSungCurve,
```

(nur `sungCurve: session.sungCurve` → `sungCurve: session.displayedSungCurve`, sonst unverändert)

- [ ] **Step 3: `mobile/lib/main.dart` — `SyncApi` verdrahten**

Import ergänzen (nach `import 'api/midi_api.dart';`, `mobile/lib/main.dart:7`):

```dart
import 'api/sync_api.dart';
```

`SessionState`-Konstruktion (`mobile/lib/main.dart:22-25`) erweitern:

```dart
      create: (_) => SessionState(
        midiApi: MidiApi(apiClient),
        audioApi: AudioApi(apiClient),
        syncApi: SyncApi(apiClient),
      ),
```

- [ ] **Step 4: Statische Analyse + vollständiger Testlauf**

Run: `cd mobile && flutter analyze && flutter test`
Expected: keine neuen Analyzer-Fehler, alle Tests PASS.

- [ ] **Step 5: Manuelle Verifikation im Emulator/Gerät**

Backend starten (`.venv/bin/python run.py`), App starten (`cd mobile && flutter run`), MIDI hochladen, Spur wählen, die mitgelieferte `tests/fixtures/test_vocal.wav` als Aufnahme hochladen (simuliert die 150ms-zu-früh-Note) und beobachten, dass die orange gesungene Kurve nach kurzer "Richte Aufnahme zeitlich aus…"-Phase näher an die teal Zielkurve heranrückt, statt bei Note 3 (G4) sichtbar vorzulaufen.

- [ ] **Step 6: Commit**

```bash
git add mobile/lib/widgets/pitch_chart.dart mobile/lib/screens/home_screen.dart mobile/lib/main.dart
git commit -m "feat: render DTW-aligned sung curve in PitchChart"
```

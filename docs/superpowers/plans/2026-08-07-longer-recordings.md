# Aufnahmen bis 300s + Kürzungs-Warnung Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Raise the recording-duration cap from 90s to 300s without the DTW alignment step's memory blowing up, and tell the user (instead of silently truncating) when a recording was cut down.

**Architecture:** `align_curves()` gets a new `envelope_frame_rate_hz` parameter so the DTW step can run on a coarser onset-envelope (25Hz instead of 100Hz — shrinks the dense DTW cost matrix ~16x) while the pitch curves used for scoring/display stay at 100Hz; the warping path's indices are converted to time and interpolated onto the fine-grained curve instead of being used as direct array indices. `load_audio_signal`/`analyze_pitch` are extended to report the pre-truncation duration, surfaced only through `/api/audio/analyze` (the endpoint called first, before `/api/sync/align` re-decodes the same bytes). Mobile gets a small response wrapper, new `SessionState` fields, and a new `LoadStatus.warning` tier in `StatusBanner`.

**Tech Stack:** Python (backend/sync, backend/audio_io.py, backend/pitch_detection, backend/api/routes.py), Dart/Flutter (mobile/lib/api, mobile/lib/state, mobile/lib/widgets), pytest, flutter_test.

## Global Constraints

- `MAX_AUDIO_SECONDS`: 90 → 300 (`backend/config.py`).
- `MAX_AUDIO_UPLOAD_BYTES`: 40MB → 80MB (`backend/api/routes.py` — this constant lives there, not in `config.py`).
- `MAX_SCORE_CURVE_FRAMES`: 20000 → 35000 (`backend/config.py`, must cover 300s × 100Hz = 30000).
- New `DTW_FRAME_RATE_HZ = 25.0` (`backend/config.py`) — only for the DTW onset-envelope; pitch curves (`target_curve`, `sung_curve`, everything used for scoring/chart/glide/vocal-range) stay at 100Hz, unchanged.
- Truncation is only signaled via `/api/audio/analyze`'s response — not `/api/sync/align` — since `analyzeAudio()`/`analyzeReference()` (mobile) always call `/api/audio/analyze` first with the same bytes and the same `MAX_AUDIO_SECONDS`, so if that call didn't truncate, the later `/api/sync/align` call (same bytes, same constant) won't either.
- `load_audio_signal()`'s truncation behavior itself (hard cut at the end, no start-trim) is unchanged — see its existing docstring warning about the jump-to-audio-position feature depending on this.

---

### Task 1: `align_curves`-Interpolation + `DTW_FRAME_RATE_HZ`

**Files:**
- Modify: `backend/config.py`
- Modify: `backend/sync/align.py`
- Test: `tests/test_sync.py`

**Interfaces:**
- Consumes: nothing new.
- Produces: `align_curves(target_curve, target_envelope, sung_curve, sung_envelope, envelope_frame_rate_hz: float = 100.0) -> dict` — same return shape as before (`{"sung_curve": [...], "target_duration": float}`), new optional 5th parameter. Default `100.0` keeps every existing caller's behavior numerically unchanged (verified below).

- [ ] **Step 1: Add the DTW frame-rate constant to config.py**

Append to `backend/config.py`, after the existing `DTW_BAND_RADIUS = 0.1` block (before the "Spurerkennung" section):

```python

# DTW-Ausrichtung: eigene, niedrigere Frame-Rate nur fuer die Onset-Huellkurve, die in
# die DTW-Distanzberechnung geht (nicht fuer die Pitch-Kurven, die bleiben bei 100Hz).
# librosa.sequence.dtw legt trotz Sakoe-Chiba-Band immer eine volle dichte Kosten-/
# Distanzmatrix an (kein Sparse-Speicher) - bei 100Hz wuerde ein 300s-Kurvenpaar eine
# ~30000x30000-Matrix (~14-20GB RAM) ergeben. Bei 25Hz sind es nur ~7500x7500
# (~1,3GB) - siehe docs/superpowers/specs/2026-08-07-longer-recordings-design.md.
DTW_FRAME_RATE_HZ = 25.0
```

- [ ] **Step 2: Write the failing tests**

Append to `tests/test_sync.py`, after the existing `test_align_curves_recovers_early_onset_offset` test:

```python
def test_align_curves_recovers_offset_at_lower_envelope_rate():
    # Gleiches Szenario wie test_align_curves_recovers_early_onset_offset, aber mit
    # einer von der 100Hz-Kurven-Rate entkoppelten, groeberen 25Hz-Envelope-Rate -
    # Kurven bleiben bei 100Hz (n=200 Frames / 2.0s), Envelope-Arrays sind jetzt nur
    # n=50 lang (ebenfalls 2.0s, aber bei 25Hz).
    step = 0.01
    n_curve = 200
    target_curve = [{"t": round(i * step, 3), "hz": 440.0, "midi_note": 69} for i in range(n_curve)]
    sung_curve = [
        {"t": round(i * step, 3), "hz": 440.0, "voiced": True, "confidence": 0.9}
        for i in range(n_curve)
    ]

    envelope_rate = 25.0
    n_env = 50
    target_envelope = [0.0] * n_env
    target_envelope[12] = 1.0  # Zielereignis bei t=0.48s
    sung_envelope = [0.0] * n_env
    sung_envelope[8] = 1.0  # dasselbe Ereignis 160ms zu frueh, bei t=0.32s

    result = align_curves(
        target_curve, target_envelope, sung_curve, sung_envelope,
        envelope_frame_rate_hz=envelope_rate,
    )
    # Kurven-Frame 32 (t=0.32s) ist exakt der Sung-Envelope-Anker (Frame 8 bei 25Hz).
    aligned_t = result["sung_curve"][32]["aligned_t"]
    assert aligned_t is not None
    assert aligned_t == pytest.approx(0.48, abs=0.01)


def test_align_curves_interpolates_between_envelope_anchors_instead_of_stepping():
    # Gleicher Aufbau wie oben, plus ein zweites, exakt uebereinstimmendes Ereignis bei
    # Envelope-Frame 24 (t=0.96s auf beiden Seiten) - das erzeugt einen laengeren
    # diagonalen (1:1) Pfadabschnitt danach. Kurven-Frames 52-56 (t=0.52-0.56s) liegen
    # in diesem diagonalen Abschnitt zwischen zwei benachbarten Envelope-Ankern mit
    # UNTERSCHIEDLICHEN Zielzeiten (0.52s und 0.56s) - bei echter linearer
    # Interpolation muessen die 5 Kurven-Frames dazwischen 5 verschiedene,
    # kontinuierlich steigende aligned_t-Werte bekommen, nicht denselben Stufenwert.
    # (Verifiziert per Hand gegen echtes librosa.sequence.dtw-Verhalten, nicht geraten -
    # falls eine spaetere librosa-Version den Warping-Pfad fuer dieses exakte Szenario
    # anders backtrackt, das Kernkriterium [5 verschiedene, aufsteigende Werte im
    # Fenster] beibehalten und die Frame-Indizes bei Bedarf anpassen.)
    step = 0.01
    n_curve = 200
    target_curve = [{"t": round(i * step, 3), "hz": 440.0, "midi_note": 69} for i in range(n_curve)]
    sung_curve = [
        {"t": round(i * step, 3), "hz": 440.0, "voiced": True, "confidence": 0.9}
        for i in range(n_curve)
    ]

    envelope_rate = 25.0
    n_env = 50
    target_envelope = [0.0] * n_env
    target_envelope[12] = 1.0
    target_envelope[24] = 1.0
    sung_envelope = [0.0] * n_env
    sung_envelope[8] = 1.0
    sung_envelope[24] = 1.0

    result = align_curves(
        target_curve, target_envelope, sung_curve, sung_envelope,
        envelope_frame_rate_hz=envelope_rate,
    )
    aligned = result["sung_curve"]
    window = [aligned[i]["aligned_t"] for i in range(52, 57)]
    assert all(v is not None for v in window)
    assert window == [pytest.approx(0.52 + 0.01 * k, abs=1e-9) for k in range(5)]
    assert len(set(window)) == 5, (
        "aligned_t sollte zwischen den DTW-Ankern kontinuierlich interpolieren, "
        "nicht in Stufen springen"
    )
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/test_sync.py -k "lower_envelope_rate or interpolates_between" -v`
Expected: FAIL with `TypeError: align_curves() got an unexpected keyword argument 'envelope_frame_rate_hz'`.

- [ ] **Step 4: Implement the interpolation in align_curves**

Replace `backend/sync/align.py`'s `align_curves` function signature and body (everything from `def align_curves(` to the final `return` statement) with:

```python
def align_curves(
    target_curve: list[dict],
    target_envelope: list[float],
    sung_curve: list[dict],
    sung_envelope: list[float],
    envelope_frame_rate_hz: float = 100.0,
) -> dict:
    """DTW-alignt die gesungene Onset-Huellkurve auf die Ziel-Huellkurve.

    Liefert sung_curve mit einem zusaetzlichen Feld 'aligned_t' pro Frame (die
    Zielzeit, auf die dieser Gesangs-Frame laut Warping-Pfad faellt, oder None
    wenn kein Warping-Pfad-Eintrag fuer diesen Frame existiert) sowie
    target_duration fuer die Client-x-Achsenskalierung.

    `envelope_frame_rate_hz` ist die Frame-Rate von target_envelope/sung_envelope -
    kann von der (immer 100Hz) Frame-Rate der Pitch-Kurven target_curve/sung_curve
    abweichen (siehe docs/superpowers/specs/2026-08-07-longer-recordings-design.md).
    Der DTW-Warping-Pfad liefert Indexpaare in die (moeglicherweise groebere)
    Huellkurve; diese werden zunaechst in Zeitwerte umgerechnet
    (index / envelope_frame_rate_hz), dann wird aligned_t fuer jeden (feineren)
    sung_curve-Frame linear zwischen den beiden umschliessenden Ankerpunkten
    interpoliert - nicht mehr direkt als Kurven-Index verwendet.
    """
    if not target_curve or not sung_curve or not target_envelope or not sung_envelope:
        aligned = [{**frame, "aligned_t": None} for frame in sung_curve]
        return {
            "sung_curve": aligned,
            "target_duration": target_curve[-1]["t"] if target_curve else 0.0,
        }

    x = _zscore(target_envelope)[None, :]
    y = _zscore(sung_envelope)[None, :]

    # Ein zu kurzes Kurvenpaar (< ~10 Frames je Seite) wuerde bei DTW_BAND_RADIUS=0.1 auf
    # einen Bandradius von 0 Frames runden - librosa.sequence.dtw wirft dann
    # ParameterError, weil das gesamte Kostengitter auf inf gesetzt wuerde (auch die
    # Diagonale). Fuer diesen (in der Praxis extrem seltenen) Fall faellt der Aufruf auf
    # unbegrenztes Alignment zurueck - identisch zum Verhalten vor diesem Bugfix.
    min_len = min(len(target_envelope), len(sung_envelope))
    band_is_usable = round(DTW_BAND_RADIUS * min_len) >= 1
    dtw_kwargs = {"global_constraints": True, "band_rad": DTW_BAND_RADIUS} if band_is_usable else {}
    _, wp = librosa.sequence.dtw(
        X=x, Y=y, metric="euclidean", subseq=False, backtrack=True, **dtw_kwargs,
    )

    # wp laeuft in absteigender Reihenfolge von (len(target)-1, len(sung)-1) nach (0, 0);
    # reversed(...) macht daraus die chronologische Reihenfolge. Bei mehreren
    # Ziel-Envelope-Frames fuer denselben Gesangs-Envelope-Frame gewinnt der
    # chronologisch letzte Treffer.
    n_target_env = len(target_envelope)
    n_sung_env = len(sung_envelope)
    j_to_target_time: dict[int, float] = {}
    for i, j in reversed(wp):
        if i < n_target_env and j < n_sung_env:
            j_to_target_time[int(j)] = i / envelope_frame_rate_hz

    anchor_js = sorted(j_to_target_time)
    anchor_times = [j / envelope_frame_rate_hz for j in anchor_js]
    anchor_values = [j_to_target_time[j] for j in anchor_js]

    aligned: list[dict] = []
    for frame in sung_curve:
        t = frame["t"]
        if not anchor_times:
            aligned_t = None
        elif t < anchor_times[0]:
            aligned_t = None
        elif t >= anchor_times[-1]:
            aligned_t = anchor_values[-1]
        else:
            k = bisect.bisect_right(anchor_times, t) - 1
            t0, t1 = anchor_times[k], anchor_times[k + 1]
            v0, v1 = anchor_values[k], anchor_values[k + 1]
            ratio = (t - t0) / (t1 - t0) if t1 > t0 else 0.0
            aligned_t = v0 + ratio * (v1 - v0)
        aligned.append({**frame, "aligned_t": aligned_t})

    return {
        "sung_curve": aligned,
        "target_duration": target_curve[-1]["t"],
    }
```

Add `import bisect` to the top of `backend/sync/align.py`, alongside the existing `import librosa`/`import numpy as np` lines.

- [ ] **Step 5: Run tests to verify they pass**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/test_sync.py -v`
Expected: all tests PASS, including the 2 new ones AND every pre-existing `align_curves` test unchanged (`test_align_curves_recovers_early_onset_offset`, `test_align_curves_handles_empty_input_without_raising`, `test_align_curves_handles_very_short_curves_without_band_related_crash`, `test_align_curves_self_alignment_stays_near_zero_through_a_long_pause`) — these all call `align_curves` without the new parameter, so they exercise the unchanged `envelope_frame_rate_hz=100.0` default path, which is numerically equivalent to the old index-based behavior.

- [ ] **Step 6: Run the full backend test suite for regressions**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/ -v`
Expected: all tests PASS.

- [ ] **Step 7: Commit**

```bash
git add backend/config.py backend/sync/align.py tests/test_sync.py
git commit -m "feat: interpolate align_curves' aligned_t between DTW anchors, decouple envelope frame rate from curve frame rate"
```

---

### Task 2: `routes.py`-Wiring für die DTW-Frame-Rate

**Files:**
- Modify: `backend/api/routes.py`

**Interfaces:**
- Consumes: `DTW_FRAME_RATE_HZ` (Task 1, `backend.config`), `align_curves`'s new `envelope_frame_rate_hz` parameter (Task 1).
- Produces: nothing new for later tasks — this is a pure wiring task.

- [ ] **Step 1: Wire DTW_FRAME_RATE_HZ into /api/sync/align**

In `backend/api/routes.py`, add `DTW_FRAME_RATE_HZ` to the existing `from backend.config import (...)` block (keep the import list alphabetically sorted).

In the `sync_align` function, change the three onset-envelope calls to use `DTW_FRAME_RATE_HZ` instead of the implicit 100Hz default:

```python
    sung_envelope = onset_envelope_from_signal(y_sung, sr_sung, frame_rate_hz=DTW_FRAME_RATE_HZ)
```
(replaces the existing `sung_envelope = onset_envelope_from_signal(y_sung, sr_sung)` line)

```python
        target_envelope = onset_envelope_from_signal(y_ref, sr_ref, frame_rate_hz=DTW_FRAME_RATE_HZ)
```
(replaces the existing `target_envelope = onset_envelope_from_signal(y_ref, sr_ref)` line, inside the `if reference_audio is not None:` branch)

```python
            target_envelope = onset_envelope_from_midi_track(pm, track_index, frame_rate_hz=DTW_FRAME_RATE_HZ)
```
(replaces the existing `target_envelope = onset_envelope_from_midi_track(pm, track_index)` line, inside the `elif session_id is not None and track_index is not None:` branch)

Do NOT change `pitch_curve_from_signal`/`track_pitch_curve` calls in this same function — those stay at their default 100Hz, producing `target_curve`/`sung_curve` unchanged.

Change the `align_curves` call at the end of the function:

```python
    result = align_curves(
        target_curve, target_envelope, sung_curve, sung_envelope,
        envelope_frame_rate_hz=DTW_FRAME_RATE_HZ,
    )
```
(replaces the existing `result = align_curves(target_curve, target_envelope, sung_curve, sung_envelope)` line)

- [ ] **Step 2: Run the full backend test suite**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/ -v`
Expected: all tests PASS. There is no dedicated automated test for this endpoint (this project tests functions directly rather than via `TestClient`, see `tests/test_e2e_phase3.py`/`test_e2e_phase4.py` for the pattern this endpoint mirrors) — Task 1's `align_curves` tests already cover the interpolation logic this wiring depends on.

- [ ] **Step 3: Manual sanity check**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -c "
from pathlib import Path
from backend.audio_io import load_audio_signal
from backend.pitch_detection import pitch_curve_from_signal
from backend.sync import align_curves, onset_envelope_from_signal
from backend.config import DTW_FRAME_RATE_HZ
from tests.fixtures.generate_fixtures import generate
midi_path, wav_path = generate(Path('tests/fixtures'))
y, sr, _ = load_audio_signal(wav_path.read_bytes(), filename_hint='test_vocal.wav')
curve = pitch_curve_from_signal(y, sr, frame_rate_hz=100.0)
env = onset_envelope_from_signal(y, sr, frame_rate_hz=DTW_FRAME_RATE_HZ)
result = align_curves(curve, env, curve, env, envelope_frame_rate_hz=DTW_FRAME_RATE_HZ)
print('OK, aligned', len(result[\"sung_curve\"]), 'frames, target_duration', result['target_duration'])
"`
Expected: prints `OK, aligned <N> frames, target_duration <T>` with no exception — confirms the wiring works end-to-end against the real fixture, not just synthetic unit-test data.

- [ ] **Step 4: Commit**

```bash
git add backend/api/routes.py
git commit -m "feat: use DTW_FRAME_RATE_HZ for the /api/sync/align onset envelopes"
```

---

### Task 3: `load_audio_signal`/`analyze_pitch` liefern Original-Dauer + Limits erhöhen

**Files:**
- Modify: `backend/config.py`
- Modify: `backend/audio_io.py`
- Modify: `backend/pitch_detection/pyin.py`
- Modify: `backend/api/routes.py` (only its two existing `load_audio_signal` call sites in `sync_align` — NOT the `/api/audio/analyze` endpoint yet, that's Task 4)
- Test: Create `tests/test_audio_io.py`
- Test: Modify `tests/test_pitch_detection.py`
- Test: Modify `tests/test_sync.py`, `tests/test_e2e_phase1.py`, `tests/test_e2e_phase3.py`, `tests/test_e2e_phase4.py`

**Interfaces:**
- Consumes: nothing new.
- Produces: `load_audio_signal(audio_bytes, filename_hint, max_seconds) -> tuple[np.ndarray, int, float]` (3rd element: pre-truncation duration in seconds — signature change, breaks positional 2-tuple unpacking everywhere it's called, all call sites fixed in this task). `analyze_pitch(...) -> dict` with shape `{"curve": list[dict], "truncated": bool, "original_duration_seconds": float}` (was `list[dict]` — also a breaking signature change, all call sites fixed in this task).

- [ ] **Step 1: Raise the config limits**

In `backend/config.py`, change:

```python
MAX_AUDIO_SECONDS = 90
```
to
```python
# Bis zu 5 Minuten (siehe docs/superpowers/specs/2026-08-07-longer-recordings-design.md;
# war 90s / "kurze Ausschnitte zuerst").
MAX_AUDIO_SECONDS = 300
```

And change:
```python
MAX_SCORE_CURVE_FRAMES = 20000  # ~200s bei 100Hz, grosszuegig ueber MAX_AUDIO_SECONDS
```
to
```python
MAX_SCORE_CURVE_FRAMES = 35000  # ~350s bei 100Hz, grosszuegig ueber MAX_AUDIO_SECONDS (300s)
```

In `backend/api/routes.py`, change:
```python
MAX_AUDIO_UPLOAD_BYTES = 40 * 1024 * 1024  # grosszuegig fuer 20-60s unkomprimiertes WAV
```
to
```python
MAX_AUDIO_UPLOAD_BYTES = 80 * 1024 * 1024  # 300s Stereo-44.1kHz-WAV-Upload braucht ~53MB
```

- [ ] **Step 2: Write the failing tests for load_audio_signal's new return value**

Create `tests/test_audio_io.py`:

```python
"""Tests fuer backend/audio_io.py."""

from __future__ import annotations

import io

import numpy as np
import pytest
import soundfile as sf

from backend.audio_io import AudioDecodeError, load_audio_signal

SR = 22050


def _wav_bytes(signal: np.ndarray, sr: int = SR) -> bytes:
    buf = io.BytesIO()
    sf.write(buf, signal, sr, format="WAV")
    return buf.getvalue()


def test_load_audio_signal_reports_original_duration_when_not_truncated():
    duration = 1.0
    signal = np.zeros(int(duration * SR))
    y, sr, original_duration_seconds = load_audio_signal(_wav_bytes(signal), max_seconds=90.0)
    assert original_duration_seconds == pytest.approx(1.0, abs=0.01)
    assert y.shape[0] / sr == pytest.approx(1.0, abs=0.01)  # nicht gekuerzt


def test_load_audio_signal_reports_pre_truncation_duration_when_truncated():
    duration = 3.0
    signal = np.zeros(int(duration * SR))
    y, sr, original_duration_seconds = load_audio_signal(_wav_bytes(signal), max_seconds=1.0)
    assert original_duration_seconds == pytest.approx(3.0, abs=0.01)
    assert y.shape[0] / sr == pytest.approx(1.0, abs=0.01)  # tatsaechlich gekuerzt auf 1.0s


def test_load_audio_signal_rejects_empty_bytes():
    with pytest.raises(AudioDecodeError):
        load_audio_signal(b"")
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/test_audio_io.py -v`
Expected: FAIL with `ValueError: too many values to unpack (expected 2)` on the 3-value unpacking.

- [ ] **Step 4: Implement the original-duration return value in load_audio_signal**

In `backend/audio_io.py`, change the function signature and the tail of `load_audio_signal`:

```python
def load_audio_signal(
    audio_bytes: bytes,
    filename_hint: str = "upload.wav",
    max_seconds: float = 90.0,
) -> tuple[np.ndarray, int, float]:
    """Dekodiert Audio-Rohbytes zu (Samples, Sample-Rate, Original-Dauer-Sekunden),
    das Sample-Array auf max_seconds gekappt (die dritte Rueckgabe ist immer die
    UNGEKUERZTE Dauer, auch wenn tatsaechlich gekuerzt wurde - siehe
    docs/superpowers/specs/2026-08-07-longer-recordings-design.md).
    ...
```
(keep the rest of the existing docstring content — the "ACHTUNG: Der Anfang..." paragraph — unchanged, just update the first line/return-shape description as shown)

Then, at the end of the function body, replace:

```python
    max_samples = int(max_seconds * sr)
    if y.shape[0] > max_samples:
        y = y[:max_samples]

    return y, sr
```

with:

```python
    original_duration_seconds = y.shape[0] / sr
    max_samples = int(max_seconds * sr)
    if y.shape[0] > max_samples:
        y = y[:max_samples]

    return y, sr, original_duration_seconds
```

- [ ] **Step 5: Fix load_audio_signal's other call sites**

In `backend/pitch_detection/pyin.py`, line with `y, sr = load_audio_signal(audio_bytes, filename_hint, max_seconds)` — this is fixed as part of Step 7 below (it's inside `analyze_pitch`, which this task also changes).

In `backend/api/routes.py`'s `sync_align` function, change:
```python
        y_sung, sr_sung = load_audio_signal(sung_bytes, sung_audio.filename or "sung.wav", MAX_AUDIO_SECONDS)
```
to
```python
        y_sung, sr_sung, _ = load_audio_signal(sung_bytes, sung_audio.filename or "sung.wav", MAX_AUDIO_SECONDS)
```

and change:
```python
            y_ref, sr_ref = load_audio_signal(
                ref_bytes, reference_audio.filename or "reference.wav", MAX_AUDIO_SECONDS,
            )
```
to
```python
            y_ref, sr_ref, _ = load_audio_signal(
                ref_bytes, reference_audio.filename or "reference.wav", MAX_AUDIO_SECONDS,
            )
```
(`/api/sync/align` doesn't surface truncation per the Global Constraints — the `_` discards the value)

In `tests/test_sync.py`, change both:
```python
    target_y, target_sr = load_audio_signal(
        target_path.read_bytes(), filename_hint="test_pause_target.wav"
    )
```
to
```python
    target_y, target_sr, _ = load_audio_signal(
        target_path.read_bytes(), filename_hint="test_pause_target.wav"
    )
```
and
```python
    sung_y, sung_sr = load_audio_signal(
        sung_path.read_bytes(), filename_hint="test_pause_sung.wav"
    )
```
to
```python
    sung_y, sung_sr, _ = load_audio_signal(
        sung_path.read_bytes(), filename_hint="test_pause_sung.wav"
    )
```

In `tests/test_e2e_phase3.py`, change:
```python
    y, sr = load_audio_signal(wav_path.read_bytes(), filename_hint="test_vocal.wav")
```
to
```python
    y, sr, _ = load_audio_signal(wav_path.read_bytes(), filename_hint="test_vocal.wav")
```

In `tests/test_e2e_phase4.py`, change the identical line the same way:
```python
    y, sr, _ = load_audio_signal(wav_path.read_bytes(), filename_hint="test_vocal.wav")
```

- [ ] **Step 6: Run tests to verify Steps 1-5 pass**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/test_audio_io.py tests/test_sync.py -v`
Expected: all PASS.

- [ ] **Step 7: Write the failing tests for analyze_pitch's new return shape**

In `tests/test_pitch_detection.py`, change the 4 call sites that capture `analyze_pitch`'s return value:

Replace:
```python
    curve = analyze_pitch(_wav_bytes(signal), filename_hint="a4.wav", fmin=65.0, fmax=1050.0)
```
with:
```python
    curve = analyze_pitch(_wav_bytes(signal), filename_hint="a4.wav", fmin=65.0, fmax=1050.0)["curve"]
```

Replace:
```python
    curve = analyze_pitch(_wav_bytes(silence))
```
with:
```python
    curve = analyze_pitch(_wav_bytes(silence))["curve"]
```

Replace the entire `test_analyze_pitch_truncates_to_max_seconds` test body:
```python
def test_analyze_pitch_truncates_to_max_seconds():
    duration = 3.0
    freq = 440.0
    t = np.arange(int(duration * SR)) / SR
    signal = 0.3 * np.sin(2 * np.pi * freq * t)

    curve = analyze_pitch(_wav_bytes(signal), max_seconds=1.0)
    assert curve[-1]["t"] <= 1.05
```
with:
```python
def test_analyze_pitch_truncates_to_max_seconds():
    duration = 3.0
    freq = 440.0
    t = np.arange(int(duration * SR)) / SR
    signal = 0.3 * np.sin(2 * np.pi * freq * t)

    result = analyze_pitch(_wav_bytes(signal), max_seconds=1.0)
    assert result["curve"][-1]["t"] <= 1.05
    assert result["truncated"] is True
    assert result["original_duration_seconds"] == pytest.approx(3.0, abs=0.1)


def test_analyze_pitch_not_truncated_when_within_max_seconds():
    duration = 1.0
    freq = 440.0
    t = np.arange(int(duration * SR)) / SR
    signal = 0.3 * np.sin(2 * np.pi * freq * t)

    result = analyze_pitch(_wav_bytes(signal), max_seconds=90.0)
    assert result["truncated"] is False
    assert result["original_duration_seconds"] == pytest.approx(1.0, abs=0.05)
```

Replace:
```python
    curve = analyze_pitch(
        _m4a_bytes(signal), filename_hint="aufnahme.m4a", fmin=65.0, fmax=1050.0
    )
```
with:
```python
    curve = analyze_pitch(
        _m4a_bytes(signal), filename_hint="aufnahme.m4a", fmin=65.0, fmax=1050.0
    )["curve"]
```

(Line `analyze_pitch(b"")` inside `pytest.raises(PitchAnalysisError):` does not capture a return value — no change needed there.)

In `tests/test_e2e_phase1.py`, change:
```python
    sung_curve = analyze_pitch(wav_path.read_bytes(), filename_hint="test_vocal.wav")
```
to
```python
    sung_curve = analyze_pitch(wav_path.read_bytes(), filename_hint="test_vocal.wav")["curve"]
```

- [ ] **Step 8: Run tests to verify they fail**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/test_pitch_detection.py -v`
Expected: FAIL — `analyze_pitch` still returns a bare list, so `result["curve"]`/`result["truncated"]` raise `TypeError: list indices must be integers...`.

- [ ] **Step 9: Implement the dict return shape in analyze_pitch**

In `backend/pitch_detection/pyin.py`, replace the `analyze_pitch` function body:

```python
def analyze_pitch(
    audio_bytes: bytes,
    filename_hint: str = "upload.wav",
    max_seconds: float = 90.0,
    fmin: float = 65.0,
    fmax: float = 1050.0,
    frame_rate_hz: float = 100.0,
) -> dict:
    """Liefert {"curve": [{t, hz|None, voiced, confidence}], "truncated": bool,
    "original_duration_seconds": float}.

    Dekodiert die Audiobytes (temporaer, wird sofort danach geloescht - siehe
    Datenschutz-Leitplanke) und delegiert die eigentliche Tonhoehenberechnung an
    pitch_curve_from_signal(). "truncated"/"original_duration_seconds" kommen direkt
    von load_audio_signal() durch (siehe docs/superpowers/specs/
    2026-08-07-longer-recordings-design.md).
    """
    try:
        y, sr, original_duration_seconds = load_audio_signal(audio_bytes, filename_hint, max_seconds)
    except AudioDecodeError as exc:
        raise PitchAnalysisError(str(exc)) from exc
    curve = pitch_curve_from_signal(y, sr, fmin=fmin, fmax=fmax, frame_rate_hz=frame_rate_hz)
    return {
        "curve": curve,
        "truncated": original_duration_seconds > max_seconds,
        "original_duration_seconds": round(original_duration_seconds, 1),
    }
```

- [ ] **Step 10: Run tests to verify they pass**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/test_pitch_detection.py tests/test_audio_io.py tests/test_sync.py -v`
Expected: all PASS.

- [ ] **Step 11: Run the full backend test suite for regressions**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/ -v`
Expected: all PASS — this project has no `TestClient`-based endpoint tests (see other specs' "kein TestClient" convention), so nothing in the suite directly exercises `backend/api/routes.py`'s `/api/audio/analyze` handler. That handler is now transiently inconsistent (it still does `curve = analyze_pitch(...)` then `return {"curve": curve}`, but `analyze_pitch` now returns a dict, not a list — a real HTTP request would get a wrongly-nested response) — this is expected and fixed in Task 4, which lands immediately after this one. Don't fix it here; that keeps this task's diff scoped to `load_audio_signal`/`analyze_pitch`'s contract.

- [ ] **Step 12: Commit**

```bash
git add backend/config.py backend/audio_io.py backend/pitch_detection/pyin.py backend/api/routes.py tests/test_audio_io.py tests/test_pitch_detection.py tests/test_sync.py tests/test_e2e_phase1.py tests/test_e2e_phase3.py tests/test_e2e_phase4.py
git commit -m "feat: report pre-truncation audio duration from load_audio_signal/analyze_pitch, raise duration/size limits"
```

---

### Task 4: `/api/audio/analyze` liefert `truncated`/`original_duration_seconds`

**Files:**
- Modify: `backend/api/routes.py`

**Interfaces:**
- Consumes: `analyze_pitch(...) -> dict` with shape `{"curve", "truncated", "original_duration_seconds"}` (Task 3).
- Produces: `POST /api/audio/analyze` response shape `{"curve": [...], "truncated": bool, "original_duration_seconds": float}` (was `{"curve": [...]}`).

- [ ] **Step 1: Update the endpoint**

In `backend/api/routes.py`'s `analyze_audio` function, replace:

```python
    try:
        curve = analyze_pitch(
            data,
            filename_hint=file.filename or "upload.wav",
            max_seconds=MAX_AUDIO_SECONDS,
            fmin=PITCH_FMIN_HZ,
            fmax=PITCH_FMAX_HZ,
        )
    except PitchAnalysisError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    return {"curve": curve}
```

with:

```python
    try:
        result = analyze_pitch(
            data,
            filename_hint=file.filename or "upload.wav",
            max_seconds=MAX_AUDIO_SECONDS,
            fmin=PITCH_FMIN_HZ,
            fmax=PITCH_FMAX_HZ,
        )
    except PitchAnalysisError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    return result
```

(`analyze_pitch`'s return dict already has exactly the shape the API response needs.)

- [ ] **Step 2: Run the full backend test suite**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -m pytest tests/ -v`
Expected: all PASS — this closes out the gap Task 3 Step 11 flagged.

- [ ] **Step 3: Manual sanity check**

Run: `/home/jrive/code/singing-feedback/.venv/bin/python -c "
from pathlib import Path
from backend.pitch_detection import analyze_pitch
from tests.fixtures.generate_fixtures import generate
midi_path, wav_path = generate(Path('tests/fixtures'))
result = analyze_pitch(wav_path.read_bytes(), filename_hint='test_vocal.wav', max_seconds=1.0)
print('truncated:', result['truncated'], 'original_duration_seconds:', result['original_duration_seconds'])
assert result['truncated'] is True
print('OK')
"`
Expected: prints `truncated: True original_duration_seconds: 5.0` (the fixture's melody is 5.0s, see `tests/fixtures/generate_fixtures.py`'s `MELODY`) and `OK`, confirming the endpoint's underlying function reports truncation correctly end-to-end against real fixture data with a deliberately-small `max_seconds`.

- [ ] **Step 4: Commit**

```bash
git add backend/api/routes.py
git commit -m "feat: return truncated/original_duration_seconds from POST /api/audio/analyze"
```

---

### Task 5: Mobile — `AudioAnalysisResult` + `SessionState`-Truncation-Felder

**Files:**
- Create: `mobile/lib/models/audio_analysis_result.dart`
- Modify: `mobile/lib/api/audio_api.dart`
- Modify: `mobile/lib/state/session_state.dart`
- Test: `mobile/test/session_state_test.dart`

**Interfaces:**
- Consumes: backend JSON shape `{"curve": [...], "truncated": bool, "original_duration_seconds": number}` from Task 4 (this task supplies its own JSON fixture in tests, no runtime coupling).
- Produces: `AudioAnalysisResult{curve: List<SungPoint>, truncated: bool, originalDurationSeconds: double}`. `AudioApi.analyzeAudio(bytes, filename) -> Future<AudioAnalysisResult>` (was `Future<List<SungPoint>>`). `SessionState.audioTruncated`/`referenceTruncated: bool`. Top-level function `String formatDurationMinSec(double seconds)` in `session_state.dart`.

- [ ] **Step 1: Write the failing tests**

In `mobile/test/session_state_test.dart`, find `_FakeApiClient`'s `postMultipart` override and its fallback `return {'curve': [...]};` block (the one used for `/api/audio/analyze`, i.e. not the `/api/sync/align` branch). Replace it:

```dart
    return {
      'curve': [
        {'t': 0.0, 'hz': 440.0, 'voiced': true, 'confidence': 0.9},
        {'t': 0.01, 'hz': null, 'voiced': false, 'confidence': 0.0},
      ],
      'truncated': false,
      'original_duration_seconds': 0.02,
    };
```

Add a new test group at the end of `main()`, before the final closing brace:

```dart
  group('SessionState Aufnahme-Kuerzung', () {
    test('formatDurationMinSec formatiert Sekunden als m:ss', () {
      expect(formatDurationMinSec(0.0), '0:00');
      expect(formatDurationMinSec(59.0), '0:59');
      expect(formatDurationMinSec(60.0), '1:00');
      expect(formatDurationMinSec(116.0), '1:56');
    });

    test('analyzeAudio() setzt audioTruncated und die Warnmeldung, wenn gekuerzt wurde', () async {
      final client = _TruncatingFakeApiClient();
      final session = SessionState(
        midiApi: MidiApi(client),
        audioApi: AudioApi(client),
        syncApi: SyncApi(client),
        scoreApi: ScoreApi(client),
        feedbackApi: FeedbackApi(client),
      );

      await session.analyzeAudio(Uint8List.fromList([1, 2, 3]), 'gesang.m4a');

      expect(session.audioTruncated, isTrue);
      expect(session.audioStatus, LoadStatus.warning);
      expect(session.audioMessage, contains('1:56'));
    });

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
```

Add a new fake class near `_FakeApiClient`'s definition (same file):

```dart
class _TruncatingFakeApiClient extends ApiClient {
  _TruncatingFakeApiClient() : super(baseUrl: 'http://fake.local');

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
    return {
      'curve': [
        {'t': 0.0, 'hz': 440.0, 'voiced': true, 'confidence': 0.9},
      ],
      'truncated': true,
      'original_duration_seconds': 116.0,
    };
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd mobile && flutter test test/session_state_test.dart`
Expected: FAIL to compile — `formatDurationMinSec`, `AudioAnalysisResult`, `session.audioTruncated`, `LoadStatus.warning` don't exist yet.

- [ ] **Step 3: Create the AudioAnalysisResult model**

Create `mobile/lib/models/audio_analysis_result.dart`:

```dart
import 'sung_point.dart';

/// Ergebnis von POST /api/audio/analyze. `truncated`/`originalDurationSeconds`
/// spiegeln backend/pitch_detection/pyin.py::analyze_pitch()s Rueckgabe - siehe
/// docs/superpowers/specs/2026-08-07-longer-recordings-design.md.
class AudioAnalysisResult {
  final List<SungPoint> curve;
  final bool truncated;
  final double originalDurationSeconds;

  const AudioAnalysisResult({
    required this.curve,
    required this.truncated,
    required this.originalDurationSeconds,
  });

  factory AudioAnalysisResult.fromJson(Map<String, dynamic> json) {
    final curve = (json['curve'] as List).cast<Map<String, dynamic>>();
    return AudioAnalysisResult(
      curve: curve.map(SungPoint.fromJson).toList(),
      truncated: json['truncated'] as bool,
      originalDurationSeconds: (json['original_duration_seconds'] as num).toDouble(),
    );
  }
}
```

- [ ] **Step 4: Update AudioApi**

In `mobile/lib/api/audio_api.dart`, replace the whole file:

```dart
import 'dart:typed_data';

import '../models/audio_analysis_result.dart';
import 'api_client.dart';

class AudioApi {
  final ApiClient _client;

  AudioApi(this._client);

  Future<AudioAnalysisResult> analyzeAudio(Uint8List bytes, String filename) async {
    final json = await _client.postMultipart(
      '/api/audio/analyze',
      fieldName: 'file',
      bytes: bytes,
      filename: filename,
    );
    return AudioAnalysisResult.fromJson(json);
  }
}
```

- [ ] **Step 5: Add LoadStatus.warning and formatDurationMinSec, update SessionState**

In `mobile/lib/state/session_state.dart`, change:
```dart
enum LoadStatus { idle, loading, ok, error }
```
to
```dart
enum LoadStatus { idle, loading, ok, warning, error }
```

Add a new top-level function near the top of the file (after the enum declarations, before the `AudioPlaybackController` abstract class):

```dart
/// Formatiert eine Sekundenzahl als m:ss, z.B. fuer Kuerzungs-Warnmeldungen
/// ("Aufnahme war 1:56 lang..."). Rundet auf ganze Sekunden.
String formatDurationMinSec(double seconds) {
  final totalSeconds = seconds.round();
  final minutes = totalSeconds ~/ 60;
  final secs = totalSeconds % 60;
  return '$minutes:${secs.toString().padLeft(2, '0')}';
}
```

Add two new fields near `sungAudioFilename`:
```dart
  bool audioTruncated = false;
  bool referenceTruncated = false;
```

Replace `analyzeAudio()`'s body:
```dart
  Future<void> analyzeAudio(Uint8List bytes, String filename) async {
    sungAudioBytes = bytes;
    sungAudioFilename = filename;
    audioStatus = LoadStatus.loading;
    audioMessage = 'Analysiere Tonhöhe der Aufnahme…';
    _resetAlignment();
    notifyListeners();
    try {
      final result = await audioApi.analyzeAudio(bytes, filename);
      sungCurve = result.curve;
      audioTruncated = result.truncated;
      audioStatus = result.truncated ? LoadStatus.warning : LoadStatus.ok;
      audioMessage = result.truncated
          ? 'Analyse fertig. Achtung: Aufnahme war '
              '${formatDurationMinSec(result.originalDurationSeconds)} lang und wurde gekürzt.'
          : 'Analyse fertig.';
      notifyListeners();
      await align();
      return;
    } catch (e) {
      audioStatus = LoadStatus.error;
      audioMessage = 'Fehler: ${_messageOf(e)}';
    }
    notifyListeners();
  }
```

Replace `analyzeReference()`'s body:
```dart
  Future<void> analyzeReference(Uint8List bytes, String filename) async {
    referenceAudioBytes = bytes;
    referenceStatus = LoadStatus.loading;
    referenceMessage = 'Analysiere Referenzaufnahme…';
    // Neue Referenzaufnahme = neue Zielmelodie - siehe selectTrack() oben.
    _resetAlignment();
    notifyListeners();
    try {
      final result = await audioApi.analyzeAudio(bytes, filename);
      referenceRawCurve = result.curve;
      referenceTruncated = result.truncated;
      referenceStatus = result.truncated ? LoadStatus.warning : LoadStatus.ok;
      referenceMessage = result.truncated
          ? 'Referenz analysiert. Achtung: Aufnahme war '
              '${formatDurationMinSec(result.originalDurationSeconds)} lang und wurde gekürzt. '
              'Jetzt eine Gesangsaufnahme aufnehmen oder hochladen.'
          : 'Referenz analysiert. Jetzt eine Gesangsaufnahme aufnehmen oder hochladen.';
    } catch (e) {
      referenceStatus = LoadStatus.error;
      referenceMessage = 'Fehler: ${_messageOf(e)}';
    }
    notifyListeners();
  }
```

Add `audioTruncated = false;` to `setReferenceSource()`, right after the existing `audioMessage = '';` line, and to `_resetAudioSection()`, right after its existing `audioMessage = '';` line — both reset points already clear `sungCurve`/`audioStatus`/`audioMessage` and must clear the new field the same way, so a truncation warning from a previous recording doesn't survive into a new one.

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd mobile && flutter test test/session_state_test.dart`
Expected: all tests PASS, including the 3 new ones.

- [ ] **Step 7: Run the full mobile test suite for regressions**

Run: `cd mobile && flutter test`
Expected: all tests PASS. If any OTHER test file has its own fake `postMultipart`/`analyzeAudio` mock returning a bare `{'curve': [...]}` shape without `truncated`/`original_duration_seconds`, or directly stubs `AudioApi.analyzeAudio` to return a raw `List<SungPoint>`, fix it the same way (add the two missing keys, or adapt to the new `AudioAnalysisResult` return type) — a targeted grep for `AudioApi(` and `'curve':` across `mobile/test/` before running the suite will surface these quickly.

- [ ] **Step 8: Commit**

```bash
git add mobile/lib/models/audio_analysis_result.dart mobile/lib/api/audio_api.dart mobile/lib/state/session_state.dart mobile/test/session_state_test.dart
git commit -m "feat: surface audio-truncation info through AudioAnalysisResult and SessionState"
```

---

### Task 6: Mobile — `StatusBanner`-Warnzustand

**Files:**
- Modify: `mobile/lib/widgets/status_banner.dart`
- Test: Create `mobile/test/status_banner_test.dart`

**Interfaces:**
- Consumes: `LoadStatus.warning` (Task 5).
- Produces: no new public interface — this is the final task in the plan.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/status_banner_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singing_feedback_mobile/state/session_state.dart';
import 'package:singing_feedback_mobile/widgets/status_banner.dart';

void main() {
  testWidgets('LoadStatus.warning wird orange dargestellt', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: StatusBanner(status: LoadStatus.warning, message: 'Aufnahme wurde gekürzt.'),
      ),
    ));

    final text = tester.widget<Text>(find.text('Aufnahme wurde gekürzt.'));
    expect(text.style?.color, Colors.orange.shade300);
  });

  testWidgets('LoadStatus.ok bleibt gruen (Regressionsschutz)', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: StatusBanner(status: LoadStatus.ok, message: 'Fertig.'),
      ),
    ));

    final text = tester.widget<Text>(find.text('Fertig.'));
    expect(text.style?.color, Colors.green.shade300);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mobile && flutter test test/status_banner_test.dart`
Expected: FAIL — the warning case falls into `status_banner.dart`'s catch-all `_ => Colors.grey.shade400` branch, so the color assertion fails (`Colors.grey.shade400` != `Colors.orange.shade300`).

- [ ] **Step 3: Add the warning case**

In `mobile/lib/widgets/status_banner.dart`, change:
```dart
    final Color color = switch (status) {
      LoadStatus.error => Colors.red.shade300,
      LoadStatus.ok => Colors.green.shade300,
      _ => Colors.grey.shade400,
    };
```
to
```dart
    final Color color = switch (status) {
      LoadStatus.error => Colors.red.shade300,
      LoadStatus.ok => Colors.green.shade300,
      LoadStatus.warning => Colors.orange.shade300,
      _ => Colors.grey.shade400,
    };
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mobile && flutter test test/status_banner_test.dart`
Expected: both tests PASS.

- [ ] **Step 5: Run the full mobile test suite for regressions**

Run: `cd mobile && flutter test`
Expected: all tests PASS.

- [ ] **Step 6: Commit**

```bash
git add mobile/lib/widgets/status_banner.dart mobile/test/status_banner_test.dart
git commit -m "feat: show LoadStatus.warning in orange in StatusBanner"
```

---

## Self-Review Notes

- **Spec coverage:** Config-Limits (Task 3), DTW-Frame-Rate-Entkopplung + Interpolation (Task 1 + 2), Kürzungs-Warnung Backend (Task 3 + 4), Kürzungs-Warnung Mobile (Task 5 + 6) are all covered. Out-of-scope items from the spec (kein Truncation-Signal für MIDI-Zielspuren, kein Signal auf `/api/sync/align`, keine manuelle Limit-Änderung durch den Nutzer) are untouched by every task.
- **Type consistency checked:** `align_curves`'s new `envelope_frame_rate_hz` parameter (Task 1) is exactly what Task 2 passes from `DTW_FRAME_RATE_HZ`. `load_audio_signal`'s 3-tuple return (Task 3) matches every call site's unpacking, including the ones inside `analyze_pitch` and `sync_align`. `analyze_pitch`'s dict shape (Task 3) matches exactly what Task 4's endpoint returns verbatim, which matches exactly what Task 5's `AudioAnalysisResult.fromJson` parses. `SessionState.audioTruncated`/`LoadStatus.warning` (Task 5) match what Task 6's `StatusBanner` consumes.
- **Verified against real librosa, not guessed:** Task 1's two new tests were hand-verified against this repo's actual installed `librosa` (0.11.0) before being written into this plan — the exact warping path, anchor values, and window indices are real observed output, not assumed. The interpolation algorithm was also confirmed to reproduce every pre-existing `align_curves` test's expected values unchanged (empty input, very-short-curve, and the 100Hz early-onset-recovery case were all re-run against the new implementation before this plan was finalized).
- **No placeholders:** every step has literal code, not descriptions.

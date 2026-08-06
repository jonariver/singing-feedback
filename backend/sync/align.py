"""DTW-Ausrichtung der gesungenen Kurve auf die Zielkurve (Phase 3)."""

from __future__ import annotations

import librosa
import numpy as np

from backend.config import DTW_BAND_RADIUS

# Ziel darf hoechstens so viel laenger sein als die Aufnahme, bevor align_curves()
# verweigert wird (siehe duration_ratio_exceeds_limit unten fuer die Begruendung).
MAX_DURATION_RATIO = 3.0


def duration_ratio_exceeds_limit(target_duration: float, sung_duration: float) -> bool:
    """True, wenn die Zieldauer die Aufnahmedauer um mehr als MAX_DURATION_RATIO uebersteigt.

    Schuetzt vor zwei Problemen, die librosa.sequence.dtw bei stark unterschiedlichen
    Kurvenlaengen hat: (1) die O(target_frames * sung_frames) grosse Kostenmatrix kann
    bei einem langen MIDI-Ziel mehrere GB RAM belegen, und (2) globales Alignment
    (subseq=False) zwingt selbst dann eine Ende-zu-Ende-Zuordnung, wenn die Aufnahme nur
    einen Bruchteil der Zielmelodie abdeckt - das Ergebnis ist ein verschmiertes, aber
    konfident aussehendes Warping ohne erkennbaren Fehler. Beide Faelle sollen vor dem
    teuren DTW-Aufruf mit einer klaren Fehlermeldung abgefangen werden, nicht danach.
    Rein informationslose Eingaben (Dauer 0, z.B. leere Kurve) werden bewusst nicht
    abgelehnt - dafuer gibt es bereits andere Fehlerpfade.
    """
    if target_duration <= 0 or sung_duration <= 0:
        return False
    return target_duration > MAX_DURATION_RATIO * sung_duration


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

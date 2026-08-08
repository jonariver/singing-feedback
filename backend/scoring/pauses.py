"""Pausen/Atemstellen-Erkennung (Phase 4-Rest, Teil 3): macht der Gesang mitten in
einer gehaltenen Zielnote eine (Atem-)Pause, obwohl die Zielmelodie dort keine Pause
vorsieht?

Nutzt dieselben Bausteine wie stability.py: is_held_note()-Gate und
STABILITY_ONSET_TRIM_SECONDS (schliesst den kurzen Konsonanten-Anlauf einer Note aus,
damit ein normaler Wortanlaut wie "T"/"K" nicht faelschlich als Pause zaehlt). Anders
als notes.py's cents_series() filtert diese Funktion NICHT auf stimmhafte Frames - hier
wird gerade nach den unstimmhaften Laeufen gesucht, die cents_series() verwirft.

Die Dauer eines Laufs unstimmhafter Frames ist NICHT einfach die Differenz zwischen
letztem und erstem Frame-Zeitpunkt: jeder Frame repraesentiert ein Zeitintervall von
einer Frame-Schrittweite (`1 / frame_rate_hz`), analog zu notes.py's
segment_target_notes() (`end_t = frames[-1]["t"] + step`). Die wahre Dauer eines Laufs
ist deshalb `(letzter Zeitpunkt - erster Zeitpunkt) + Schrittweite`.

Wichtig: diese Dauer wird aus dem rohen Aufnahme-Zeitpunkt `frame["t"]` berechnet, NICHT
aus `frame["aligned_t"]` (der DTW-verzerrten Zielzeit). `aligned_t` entscheidet weiterhin,
WELCHE Frames ins Notenfenster fallen (Notengrenzen sind in Zielzeit) und in welcher
Reihenfolge Laeufe erkannt werden (Frames sind nach `aligned_t` sortiert) - aber die
tatsaechliche Laenge eines Laufs in realer Aufnahmezeit muss aus `t` kommen. Grund:
align_curves() baut den DTW-Warping-Pfad auf einem groeberen DTW_FRAME_RATE_HZ=25.0
(40ms)-Raster und interpoliert `aligned_t` linear dazwischen; wo mehrere gesungene
Frames auf denselben Zielzeit-Ankerpunkt abbilden, gewinnt nur der chronologisch letzte
(siehe align.py). Dadurch kann `aligned_t` gerade in stillen/merkmalslosen Abschnitten -
exakt dort, wo Pausenerkennung hinschaut - nicht gleichmaessig zur echten verstrichenen
Zeit stehen. `aligned_t` ist dabei monoton nicht-fallend (die DTW-Backtracking-Pfad ist
monoton in beiden Indizes, und die lineare Interpolation dazwischen erhaelt das), ein in
`aligned_t`-Reihenfolge zusammenhaengender Lauf ist deshalb auch in echter Aufnahmezeit
zusammenhaengend - die Substitution von `aligned_t` durch `t` fuer die Dauerberechnung
ist also lokal sicher.

Bekannte Einschraenkung: notes.py's segment_target_notes() ueberbrueckt kurze unstimmhafte
Luecken in der ZIELKURVE (bis zu NOTE_SEGMENT_MAX_BRIDGE_GAP_FRAMES Frames, aktuell 150ms
bei 100Hz) zu einer einzigen Note. Eine echte kurze Pause in der Zielmelodie kann so
INNERHALB einer von compute_pause() als durchgehend behandelten Note landen. Da
PAUSE_MIN_GAP_SECONDS=0.25s nur 100ms ueber dieser 150ms-Bruecken-Schwelle liegt, hat ein
Saenger, der genau an so einer legitimen kurzen Zielpause atmet, nur ~100ms Puffer, bevor
er faelschlich als "unerwartete Pause" geflaggt wird. Dies wird bewusst NICHT behoben
(dafuer muesste compute_pause() Zielkurven-Stimmhaftigkeit kennen, eine Schnittstellen-
aenderung, die auch score.py's Aufrufstelle betrifft) - falls PAUSE_MIN_GAP_SECONDS
jemals nach unten kalibriert wird, muss es deutlich ueber
NOTE_SEGMENT_MAX_BRIDGE_GAP_FRAMES / frame_rate_hz bleiben, sonst verschaerft sich diese
Klasse von Fehlalarmen.
"""

from __future__ import annotations

from backend.config import PAUSE_MIN_GAP_SECONDS, STABILITY_ONSET_TRIM_SECONDS
from backend.scoring.stability import is_held_note

NOT_APPLICABLE_PAUSE = {"applicable": False, "gap_seconds": None, "flag": False}


def compute_pause(note: dict, attributed_frames: list[dict], frame_rate_hz: float = 100.0) -> dict:
    if not is_held_note(note):
        return dict(NOT_APPLICABLE_PAUSE)

    step = 1.0 / frame_rate_hz
    window_start = note["start_t"] + STABILITY_ONSET_TRIM_SECONDS
    window_end = note["end_t"]
    frames = sorted(
        (
            f for f in attributed_frames
            if f.get("aligned_t") is not None and window_start <= f["aligned_t"] < window_end
        ),
        key=lambda f: f["aligned_t"],
    )
    if not frames:
        return dict(NOT_APPLICABLE_PAUSE)

    longest_gap = 0.0
    run_start = None
    run_end = None
    for frame in frames:
        # Fensterzugehoerigkeit und Lauf-Reihenfolge basieren auf aligned_t (oben, beim
        # Sortieren/Filtern) - die Dauer eines Laufs wird aber aus dem rohen
        # Aufnahme-Zeitpunkt t berechnet, nicht aus aligned_t (siehe Modul-Docstring).
        t = frame["t"]
        unvoiced = not frame.get("voiced") or frame.get("hz") is None
        if unvoiced:
            if run_start is None:
                run_start = t
            run_end = t
        elif run_start is not None:
            longest_gap = max(longest_gap, run_end - run_start + step)
            run_start = None
    if run_start is not None:
        longest_gap = max(longest_gap, run_end - run_start + step)

    return {
        "applicable": True,
        "gap_seconds": round(longest_gap, 3),
        "flag": longest_gap > PAUSE_MIN_GAP_SECONDS,
    }

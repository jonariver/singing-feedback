"""Extrahiert Messwerte aus einem ScoreResult (backend/scoring/score.py::score_performance())
fuer den Claude-Feedback-Prompt und baut daraus den Prompt-Text. Trennt bewusst
Messwert (harte Zahlen aus context) von der Aufgabe an Claude (siehe build_prompt_text)."""

from __future__ import annotations

# Deckelt die Anzahl der in den Prompt aufgenommenen auffaelligen Noten, unabhaengig
# davon, wie viele Noten score_result mitbringt. Ohne diese Grenze koennte ein
# Aufrufer (der /api/feedback-Endpoint prueft nur die Gesamtgroesse des Requests,
# nicht die Notenzahl) mit einem grossen, synthetischen score-Dict einen beliebig
# grossen, voll kostenpflichtigen Anthropic-Prompt erzwingen. Claude braucht ohnehin
# nur genug Problem-Noten, um bis zu 3 Punkte abzuleiten.
_MAX_FLAGGED_NOTES_IN_PROMPT = 50


def build_prompt_context(score_result: dict) -> dict:
    """Extrahiert die Summary-Zahlen plus eine kompakte Liste der auffaelligen Noten
    (verfehlt, Cent-Klassifizierung rot, oder timing-/stabilitaets-/drift-geflaggt).
    Unauffaellige Noten werden nicht mitgeschickt, um Tokens zu sparen und Claude
    nicht mit Nicht-Problemen abzulenken."""
    summary = score_result["summary"]
    flagged_notes = []
    for note in score_result["notes"]:
        is_flagged = (
            note["missed"]
            or note["cents_deviation"]["classification"] == "red"
            or note["timing"]["classification"] != "on_time"
            or note["stability"]["flag"]
            or note["phrase_end_drift"]["flag"]
        )
        if is_flagged:
            flagged_notes.append({
                "index": note["index"],
                "missed": note["missed"],
                "cents_classification": note["cents_deviation"]["classification"],
                "cents_value": note["cents_deviation"]["value"],
                "timing_classification": note["timing"]["classification"],
                "timing_deviation_ms": note["timing"]["deviation_ms"],
                "stability_flag": note["stability"]["flag"],
                "phrase_end_drift_flag": note["phrase_end_drift"]["flag"],
                "phrase_end_drift_direction": note["phrase_end_drift"]["direction"],
            })
    return {"summary": summary, "flagged_notes": flagged_notes[:_MAX_FLAGGED_NOTES_IN_PROMPT]}


def build_prompt_text(context: dict) -> str:
    """Baut den Prompt-Text: trennt klar die uebergebenen Messwerte (Fakten) von der
    Aufgabe an Claude (priorisierte Punkte ableiten, keine Vermutungen ueber nicht
    gemessene Dinge)."""
    summary = context["summary"]
    flagged_notes = context["flagged_notes"]

    lines = [
        "Du bist Gesangscoach und wertest die Messwerte einer Gesangsaufnahme aus, "
        "die mit einer Zielmelodie verglichen wurde.",
        "",
        "MESSWERTE (Fakten, direkt aus der Audioanalyse - keine Interpretation):",
        f"- Anzahl bewerteter Noten: {summary['note_count']}",
        f"- Verfehlte Noten: {summary['missed_count']}",
        f"- Cent-Abweichung: {summary['cents_green']} gruen, {summary['cents_yellow']} gelb, "
        f"{summary['cents_red']} rot",
        f"- Timing-Probleme (zu frueh/spaet): {summary['timing_flagged_count']} Noten",
        f"- Instabile gehaltene Toene: {summary['stability_flagged_count']} Noten",
        f"- Absinkende Phrasenenden: {summary['phrase_end_drift_flagged_count']} Noten",
        f"- Gesamtwertung: {summary['overall_score']}/100",
        "",
        "AUFFAELLIGE EINZELNOTEN (nur die mit einem Problem, zur Orientierung):",
    ]
    if flagged_notes:
        for note in flagged_notes:
            parts = [f"Note {note['index'] + 1}:"]
            if note["missed"]:
                parts.append("verfehlt")
            if note["cents_classification"] == "red" and note["cents_value"] is not None:
                parts.append(f"Cent-Abweichung {note['cents_value']:.0f}")
            if note["timing_classification"] != "on_time":
                parts.append(f"Timing {note['timing_classification']} ({note['timing_deviation_ms']}ms)")
            if note["stability_flag"]:
                parts.append("instabil")
            if note["phrase_end_drift_flag"]:
                parts.append(f"Phrasenende sackt ab ({note['phrase_end_drift_direction']})")
            lines.append("- " + " ".join(parts))
    else:
        lines.append("- keine")
    lines += [
        "",
        "AUFGABE: Leite aus GENAU DIESEN Messwerten bis zu 3 priorisierte, konkrete "
        "Feedback-Punkte ab - das groesste Problem zuerst. Nutze fuer jeden Punkt "
        "ausschliesslich eine Uebung aus dem bereitgestellten Katalog (uebung_id). "
        "Erfinde keine Probleme oder Uebungen, die nicht durch die Messwerte oder den "
        "Katalog gedeckt sind. Formuliere 'problem' als kurzen, konkreten Satz auf "
        "Deutsch, der sich auf die Messwerte bezieht.",
    ]
    return "\n".join(lines)

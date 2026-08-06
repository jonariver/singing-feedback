"""Orchestriert die Claude-Feedback-Generierung (Analogie zu scoring/score.py):
Katalog laden, Messwerte aus einem ScoreResult extrahieren, Anthropic per Tool-Use
aufrufen, Antwort gegen den Katalog validieren/anreichern."""

from __future__ import annotations

from typing import Any, Callable

import anthropic

from backend.config import ANTHROPIC_API_KEY, ANTHROPIC_MODEL
from backend.feedback.catalog import catalog_ids, load_catalog, lookup
from backend.feedback.client import request_feedback_points
from backend.feedback.prompt import build_prompt_context, build_prompt_text


class FeedbackUnavailableError(Exception):
    """API-Key fehlt oder der Anthropic-Aufruf ist fehlgeschlagen."""


# Stabile, generische Fehlermeldung fuer alles, was via routes.py::feedback() als
# HTTP-Detail beim Client landet - nie die rohe Exception (kann englische JSON-
# Fehlertexte des Anthropic-SDK enthalten) oder interne Konfigurationsnamen wie den
# Env-Var-Namen durchreichen ("der Fehler wird nicht verschluckt, aber auch keine
# Stacktrace-Details an den Client durchgereicht"). Die eigentliche Ursache bleibt
# ueber "from exc" fuer Server-seitige Diagnose in __cause__ erhalten.
_UNAVAILABLE_MESSAGE = "Feedback ist derzeit nicht verfügbar. Bitte später erneut versuchen."


def _matches_timing(note: dict) -> bool:
    return note["timing_classification"] != "on_time"


def _matches_drift(note: dict) -> bool:
    return note["phrase_end_drift_flag"]


def _matches_stability(note: dict) -> bool:
    return note["stability_flag"]


def _matches_missed(note: dict) -> bool:
    return note["missed"] or note["cents_classification"] == "red"


# Bildet dieselbe Bedeutung wie die _PROBLEM_TAG_*-Konstanten in scoring/score.py ab:
# welches Feld einer geflaggten Note (siehe prompt.py::build_prompt_context) macht sie
# zu einem Kandidaten fuer die jeweilige Katalog-Kategorie. "haeufiges_hineingleiten"
# hat bewusst keinen Matcher - Glide-Erkennung ist noch nicht gebaut, problem_tags
# enthaelt diesen Wert nie, also kommt uebung_id dafuer auch nie vor generate_feedback an.
_CATEGORY_MATCHERS: dict[str, Callable[[dict], bool]] = {
    "timingprobleme": _matches_timing,
    "absinkende_phrasenenden": _matches_drift,
    "instabile_lange_toene": _matches_stability,
    "unsaubere_einsaetze": _matches_missed,
}


def _find_jump_to_t(flagged_notes: list[dict], uebung_id: str, used_notes: set[int]) -> float | None:
    """Sucht die erste Note in flagged_notes, die zur Kategorie uebung_id passt, eine
    Zeitstelle (sung_t) hat und noch nicht von einem frueheren Punkt derselben Antwort
    verwendet wurde (used_notes, ueber die gesamte Punkt-Verarbeitungsschleife hinweg
    gefuehrt) - damit bei mehreren Punkten derselben Kategorie nicht alle zur gleichen
    Stelle springen. Markiert die gefundene Note als verbraucht. flagged_notes ist
    dieselbe (ggf. bei >150 Eintraegen gleichmaessig ausgeduennte) Liste, die auch den
    Claude-Prompt gespeist hat - die Zeitstelle bleibt also konsistent mit dem, was
    Claude tatsaechlich gesehen hat."""
    matcher = _CATEGORY_MATCHERS.get(uebung_id)
    if matcher is None:
        return None
    for note in flagged_notes:
        if note["index"] in used_notes:
            continue
        if note["sung_t"] is None:
            continue
        if matcher(note):
            used_notes.add(note["index"])
            return note["sung_t"]
    return None


def generate_feedback(
    score_result: dict,
    messages_client_factory: Callable[[], Any] | None = None,
) -> dict:
    """Liefert {"points": [...]} mit bis zu 3 Punkten (problem, technik, uebung,
    wiederholungsaufgabe, jump_to_t). Leere Liste, wenn score_result["summary"]
    ["problem_tags"] leer ist (kein API-Aufruf noetig). Wirft FeedbackUnavailableError,
    wenn der API-Key fehlt oder der Anthropic-Aufruf fehlschlaegt. jump_to_t ist die
    Position (Sekunden) in der eigenen Aufnahme der ersten unverbrauchten Note dieser
    Kategorie mit Zeitstelle, oder None. messages_client_factory ist injizierbar fuer
    Tests (siehe test_feedback.py) - Default baut einen echten anthropic.Anthropic-
    Client."""
    if not score_result["summary"]["problem_tags"]:
        return {"points": []}

    if not ANTHROPIC_API_KEY:
        raise FeedbackUnavailableError(_UNAVAILABLE_MESSAGE)

    if messages_client_factory is None:
        messages_client_factory = lambda: anthropic.Anthropic(api_key=ANTHROPIC_API_KEY).messages

    catalog = load_catalog()
    context = build_prompt_context(score_result)
    prompt_text = build_prompt_text(context)

    try:
        raw_points = request_feedback_points(
            messages_client_factory(), ANTHROPIC_MODEL, prompt_text, catalog_ids(catalog)
        )
    except Exception as exc:
        raise FeedbackUnavailableError(_UNAVAILABLE_MESSAGE) from exc

    used_notes: set[int] = set()
    points = []
    for raw in raw_points[:3]:
        entry = lookup(catalog, raw.get("uebung_id", ""))
        if entry is None:
            continue
        uebung_id = raw.get("uebung_id", "")
        points.append({
            "problem": raw.get("problem") or entry["problem"],
            "technik": entry["technik"],
            "uebung": entry["uebung"],
            "wiederholungsaufgabe": raw.get("wiederholungsaufgabe"),
            "jump_to_t": _find_jump_to_t(context["flagged_notes"], uebung_id, used_notes),
        })
    return {"points": points}

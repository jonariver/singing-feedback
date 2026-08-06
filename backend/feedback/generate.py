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


def generate_feedback(
    score_result: dict,
    messages_client_factory: Callable[[], Any] | None = None,
) -> dict:
    """Liefert {"points": [...]} mit bis zu 3 Punkten (problem, technik, uebung,
    wiederholungsaufgabe). Leere Liste, wenn score_result["summary"]["problem_tags"]
    leer ist (kein API-Aufruf noetig). Wirft FeedbackUnavailableError, wenn der
    API-Key fehlt oder der Anthropic-Aufruf fehlschlaegt. messages_client_factory
    ist injizierbar fuer Tests (siehe test_feedback.py) - Default baut einen echten
    anthropic.Anthropic-Client."""
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

    points = []
    for raw in raw_points[:3]:
        entry = lookup(catalog, raw.get("uebung_id", ""))
        if entry is None:
            continue
        points.append({
            "problem": raw.get("problem") or entry["problem"],
            "technik": entry["technik"],
            "uebung": entry["uebung"],
            "wiederholungsaufgabe": raw.get("wiederholungsaufgabe"),
        })
    return {"points": points}

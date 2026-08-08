"""Orchestriert die Claude-Feedback-Generierung (Analogie zu scoring/score.py):
Katalog laden, Messwerte aus einem ScoreResult extrahieren, Anthropic per Tool-Use
aufrufen, Antwort gegen den Katalog validieren/anreichern."""

from __future__ import annotations

from typing import Any, Callable

import anthropic

from backend.config import ANTHROPIC_API_KEY, ANTHROPIC_MODEL
from backend.config import CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_API_TOKEN, CLOUDFLARE_MODEL
from backend.feedback.catalog import catalog_ids, load_catalog, lookup
from backend.feedback.client import request_feedback_points
from backend.feedback.cloudflare_client import CloudflareWorkersAIClient
from backend.feedback.cloudflare_client import request_feedback_points as request_feedback_points_cloudflare
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


def _matches_glide(note: dict) -> bool:
    return note["glide_flag"]


def _matches_pause(note: dict) -> bool:
    return note["pause_flag"]


# Bildet dieselbe Bedeutung wie die _PROBLEM_TAG_*-Konstanten in scoring/score.py ab:
# welches Feld einer geflaggten Note (siehe prompt.py::build_prompt_context) macht sie
# zu einem Kandidaten fuer die jeweilige Katalog-Kategorie.
_CATEGORY_MATCHERS: dict[str, Callable[[dict], bool]] = {
    "timingprobleme": _matches_timing,
    "absinkende_phrasenenden": _matches_drift,
    "instabile_lange_toene": _matches_stability,
    "unsaubere_einsaetze": _matches_missed,
    "haeufiges_hineingleiten": _matches_glide,
    "unerwartete_pause_in_gehaltener_note": _matches_pause,
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
    provider: str = "anthropic",
    messages_client_factory: Callable[[], Any] | None = None,
    cloudflare_client_factory: Callable[[], Any] | None = None,
) -> dict:
    """Liefert {"points": [...]} mit bis zu 3 Punkten (problem, technik, uebung,
    wiederholungsaufgabe, jump_to_t). Leere Liste, wenn score_result["summary"]
    ["problem_tags"] leer ist (kein API-Aufruf noetig). provider ist "anthropic"
    (Default) oder "cloudflare" - waehlt, welcher externe Anbieter fuer die
    Feedback-Generierung genutzt wird (siehe
    docs/superpowers/specs/2026-08-08-cloudflare-feedback-provider-design.md).
    Wirft FeedbackUnavailableError, wenn die noetigen Zugangsdaten fuer den
    gewaehlten Provider fehlen, der Provider unbekannt ist, oder der externe
    Aufruf fehlschlaegt. jump_to_t ist die Position (Sekunden) in der eigenen
    Aufnahme der ersten unverbrauchten Note dieser Kategorie mit Zeitstelle,
    oder None. messages_client_factory/cloudflare_client_factory sind
    injizierbar fuer Tests (siehe test_feedback.py) - Default baut jeweils
    einen echten Client fuer den gewaehlten Provider."""
    if not score_result["summary"]["problem_tags"]:
        return {"points": []}

    if provider == "anthropic":
        if not ANTHROPIC_API_KEY:
            raise FeedbackUnavailableError(_UNAVAILABLE_MESSAGE)
        if messages_client_factory is None:
            messages_client_factory = lambda: anthropic.Anthropic(api_key=ANTHROPIC_API_KEY).messages
    elif provider == "cloudflare":
        if not CLOUDFLARE_ACCOUNT_ID or not CLOUDFLARE_API_TOKEN:
            raise FeedbackUnavailableError(_UNAVAILABLE_MESSAGE)
        if cloudflare_client_factory is None:
            cloudflare_client_factory = lambda: CloudflareWorkersAIClient(
                CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_API_TOKEN
            )
    else:
        raise FeedbackUnavailableError(_UNAVAILABLE_MESSAGE)

    catalog = load_catalog()
    context = build_prompt_context(score_result)
    prompt_text = build_prompt_text(context)

    try:
        if provider == "anthropic":
            raw_points = request_feedback_points(
                messages_client_factory(), ANTHROPIC_MODEL, prompt_text, catalog_ids(catalog)
            )
        else:
            raw_points = request_feedback_points_cloudflare(
                cloudflare_client_factory(), CLOUDFLARE_MODEL, prompt_text, catalog_ids(catalog)
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

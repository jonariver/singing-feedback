"""Kapselt den Anthropic-API-Aufruf per Tool-Use, um strukturierte Feedback-Punkte
zu bekommen (statt fragiles Freitext-Parsing). uebung_id ist im Tool-Schema als
Enum auf die tatsaechlichen Katalog-IDs beschraenkt - Claude kann technisch keine
erfundene Uebungs-ID zurueckgeben."""

from __future__ import annotations

import json
from typing import Any, Protocol

_TOOL_NAME = "return_feedback_points"


class AnthropicMessagesClient(Protocol):
    """Minimale Schnittstelle, die request_feedback_points von einem Anthropic-
    Messages-Client braucht - injizierbar fuer Tests (siehe test_feedback.py:
    _FakeMessagesClient). generate.py uebergibt client.messages eines echten
    anthropic.Anthropic-Clients."""

    def create(self, **kwargs: Any) -> Any: ...


def _tool_schema(catalog_ids: list[str]) -> dict:
    return {
        "name": _TOOL_NAME,
        "description": "Gibt bis zu 3 priorisierte Feedback-Punkte fuer eine Gesangsaufnahme zurueck.",
        "input_schema": {
            "type": "object",
            "properties": {
                "points": {
                    "type": "array",
                    "maxItems": 3,
                    "items": {
                        "type": "object",
                        "properties": {
                            "problem": {"type": "string"},
                            "uebung_id": {"type": "string", "enum": catalog_ids},
                            "wiederholungsaufgabe": {"type": "string"},
                        },
                        "required": ["problem", "uebung_id"],
                    },
                },
            },
            "required": ["points"],
        },
    }


def _normalize_points(points: Any) -> list[dict]:
    """Claude haelt sich trotz striktem Tool-Schema ("points" ist ein Array von
    Objekten) live beobachtet NICHT zuverlaessig daran, speziell bei laengeren/
    komplexeren Aufnahmen (viele Noten, mehrere lange Punkte). Drei verschiedene
    Fehlformen wurden bei wiederholten echten Aufrufen mit demselben Prompt
    beobachtet - nicht nur eine, was auf grundsaetzliche Instabilitaet der
    Tool-Call-Verschachtelung bei diesem Prompt-Umfang hindeutet, nicht auf einen
    einzelnen Sonderfall:
      1. "points" als JSON-kodierter String statt als natives Array.
      2. "points" als einzelnes Objekt statt als 1-elementiges Array (bei genau
         einem Feedback-Punkt).
      3. "points" als 1-elementiges Array, dessen einziges Element wiederum ein
         Objekt mit einem verschachtelten "points"-Schluessel ist (doppelt
         gewrappt).
    Statt fuer jede neu beobachtete Fehlform einen weiteren Sonderfall anzuflicken,
    entpackt diese Funktion iterativ (bis zu 5 Runden, gegen pathologische/zyklische
    Eingaben), bis eine flache Liste von Punkt-Dicts uebrig bleibt oder die Form
    eindeutig nicht mehr sinnvoll interpretierbar ist."""
    for _ in range(5):
        if isinstance(points, str):
            try:
                points = json.loads(points)
            except json.JSONDecodeError as exc:
                raise RuntimeError(
                    "Anthropic-Antwort enthielt ein nicht parsbares points-Feld."
                ) from exc
        elif isinstance(points, dict):
            # Ein echtes Punkt-Objekt hat "problem"/"uebung_id", kein "points" -
            # nur ein Wrapper-Dict wie {"points": [...]} wird entpackt.
            if "points" in points and "problem" not in points and "uebung_id" not in points:
                points = points["points"]
            else:
                points = [points]
        elif isinstance(points, list):
            if (
                len(points) == 1
                and isinstance(points[0], dict)
                and "points" in points[0]
                and "problem" not in points[0]
            ):
                points = points[0]["points"]
            else:
                return points
        else:
            raise RuntimeError(
                f"Anthropic-Antwort enthielt ein unerwartetes points-Feld ({type(points).__name__})."
            )
    raise RuntimeError("Anthropic-Antwort: points-Feld zu tief verschachtelt.")


def request_feedback_points(
    messages_client: AnthropicMessagesClient,
    model: str,
    prompt_text: str,
    catalog_ids: list[str],
) -> list[dict]:
    """Ruft messages_client.create() per Tool-Use auf und gibt die rohen
    {problem, uebung_id, wiederholungsaufgabe?}-Punkte zurueck. Wirft RuntimeError,
    wenn die Antwort keinen verwertbaren tool_use-Block enthaelt - generate.py
    uebernimmt die weitere Fehlerbehandlung nach aussen."""
    response = messages_client.create(
        model=model,
        max_tokens=1024,
        tools=[_tool_schema(catalog_ids)],
        tool_choice={"type": "tool", "name": _TOOL_NAME},
        messages=[{"role": "user", "content": prompt_text}],
    )
    for block in response.content:
        if getattr(block, "type", None) == "tool_use" and getattr(block, "name", None) == _TOOL_NAME:
            return _normalize_points(block.input.get("points", []))
    raise RuntimeError("Anthropic-Antwort enthielt keinen verwertbaren tool_use-Block.")

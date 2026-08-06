"""Kapselt den Anthropic-API-Aufruf per Tool-Use, um strukturierte Feedback-Punkte
zu bekommen (statt fragiles Freitext-Parsing). uebung_id ist im Tool-Schema als
Enum auf die tatsaechlichen Katalog-IDs beschraenkt - Claude kann technisch keine
erfundene Uebungs-ID zurueckgeben."""

from __future__ import annotations

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
            return block.input.get("points", [])
    raise RuntimeError("Anthropic-Antwort enthielt keinen verwertbaren tool_use-Block.")

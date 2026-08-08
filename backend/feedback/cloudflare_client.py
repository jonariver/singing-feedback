"""Kapselt den Cloudflare-Workers-AI-Aufruf per REST + Function-Calling, als
Alternative zu client.py (Anthropic). Gleiche Garantie wie bei Anthropic:
uebung_id ist im Tool-Schema als Enum auf die tatsaechlichen Katalog-IDs
beschraenkt. Nutzt _normalize_points() aus client.py wieder, statt sie zu
duplizieren - ein kleineres Modell wie Qwen3-30B-A3B haelt sich vermutlich noch
weniger zuverlaessig ans Schema als Claude (siehe die dort dokumentierten,
live beobachteten Fehlformen)."""

from __future__ import annotations

import json
from typing import Any, Protocol

import httpx

from backend.feedback.client import _normalize_points

_TOOL_NAME = "return_feedback_points"


class CloudflareMessagesClient(Protocol):
    """Minimale Schnittstelle, die request_feedback_points von einem Cloudflare-
    Client braucht - injizierbar fuer Tests (siehe test_feedback.py:
    _FakeCloudflareClient). generate.py uebergibt eine echte
    CloudflareWorkersAIClient-Instanz."""

    def create(self, **kwargs: Any) -> dict: ...


class CloudflareWorkersAIClient:
    """Ruft POST .../accounts/{account_id}/ai/run/{model} auf. Account-ID und
    API-Token werden beim Bau gebacken (analog anthropic.Anthropic(api_key=...)),
    http_client ist injizierbar fuer Tests (kein echter Netzwerkzugriff)."""

    def __init__(
        self, account_id: str, api_token: str, http_client: httpx.Client | None = None,
    ) -> None:
        self._account_id = account_id
        self._api_token = api_token
        self._http_client = http_client or httpx.Client(timeout=30.0)

    def create(self, *, model: str, messages: list[dict], tools: list[dict]) -> dict:
        url = f"https://api.cloudflare.com/client/v4/accounts/{self._account_id}/ai/run/{model}"
        response = self._http_client.post(
            url,
            headers={"Authorization": f"Bearer {self._api_token}"},
            json={"messages": messages, "tools": tools},
        )
        response.raise_for_status()
        return response.json()


def _tool_schema_openai(catalog_ids: list[str]) -> dict:
    return {
        "type": "function",
        "function": {
            "name": _TOOL_NAME,
            "description": "Gibt bis zu 3 priorisierte Feedback-Punkte fuer eine Gesangsaufnahme zurueck.",
            "parameters": {
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
        },
    }


def request_feedback_points(
    client: CloudflareMessagesClient,
    model: str,
    prompt_text: str,
    catalog_ids: list[str],
) -> list[dict]:
    """Ruft client.create() per Function-Calling auf und gibt die rohen
    {problem, uebung_id, wiederholungsaufgabe?}-Punkte zurueck - gleiche
    Rueckgabeform wie client.py::request_feedback_points (Anthropic), damit
    generate.py beide Provider identisch weiterverarbeiten kann. Wirft
    RuntimeError, wenn die Antwort keinen verwertbaren tool_calls-Eintrag
    enthaelt."""
    response = client.create(
        model=model,
        messages=[{"role": "user", "content": prompt_text}],
        tools=[_tool_schema_openai(catalog_ids)],
    )
    tool_calls = response.get("result", {}).get("tool_calls") or []
    for call in tool_calls:
        if call.get("name") != _TOOL_NAME:
            continue
        arguments = call.get("arguments", {})
        # Cloudflares eigene Dokumentation deklariert "arguments" als Typ
        # "unknown" - je nach Modell kann es ein bereits geparstes Objekt oder
        # ein JSON-kodierter String sein. Ein verschachteltes "function"-Feld
        # (OpenAI-Kompatibilitaetsformat) wird ebenfalls defensiv abgefangen,
        # falls Cloudflare das Antwortformat je angleicht.
        if "function" in call and "arguments" in call["function"]:
            arguments = call["function"]["arguments"]
        if isinstance(arguments, str):
            try:
                arguments = json.loads(arguments)
            except json.JSONDecodeError as exc:
                raise RuntimeError(
                    "Cloudflare-Antwort enthielt ein nicht parsbares arguments-Feld."
                ) from exc
        points = arguments.get("points", []) if isinstance(arguments, dict) else arguments
        return _normalize_points(points)
    raise RuntimeError("Cloudflare-Antwort enthielt keinen verwertbaren tool_calls-Eintrag.")

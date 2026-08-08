"""Kapselt den Cloudflare-Workers-AI-Aufruf per REST + Function-Calling, als
Alternative zu client.py (Anthropic). Gleiche Garantie wie bei Anthropic:
uebung_id ist im Tool-Schema als Enum auf die tatsaechlichen Katalog-IDs
beschraenkt. Nutzt _normalize_points() aus client.py wieder, statt sie zu
duplizieren - ein kleineres Modell wie Qwen3-30B-A3B haelt sich vermutlich noch
weniger zuverlaessig ans Schema als Claude (siehe die dort dokumentierten,
live beobachteten Fehlformen).

ACHTUNG - UNVERIFIZIERTE LIVE-FORM: Zum Zeitpunkt dieser Implementierung
existieren in dieser Umgebung weder CLOUDFLARE_ACCOUNT_ID noch
CLOUDFLARE_API_TOKEN - es wurde also noch KEIN einziger echter Aufruf gegen
Workers AI gemacht. Die beiden in request_feedback_points() unten behandelten
tool_calls-Formen (flach vs. OpenAI-kompatibel verschachtelt) sind beide aus
Cloudflares Dokumentation und defensivem Coding abgeleitet, nicht aus einer
tatsaechlich beobachteten Antwort (im Gegensatz zu den bei Anthropic
dokumentierten Fehlformen, die live beobachtet wurden - client.py::
_normalize_points()). Es ist moeglich, dass die echte Form von beiden
Annahmen abweicht. Wer als erstes echte Zugangsdaten setzt und einen echten
Aufruf macht: bitte das rohe Antwort-JSON gegen die Annahmen in diesem Modul
(hier und in request_feedback_points()) pruefen, bevor dieser Pfad in
Produktion vertraut wird."""

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

    def create(
        self, *, model: str, messages: list[dict], tools: list[dict], max_tokens: int,
    ) -> dict:
        url = f"https://api.cloudflare.com/client/v4/accounts/{self._account_id}/ai/run/{model}"
        response = self._http_client.post(
            url,
            headers={"Authorization": f"Bearer {self._api_token}"},
            json={"messages": messages, "tools": tools, "max_tokens": max_tokens},
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
        # Qwen3 ist ein "Reasoning"-Modell: es generiert vor der eigentlichen
        # Antwort eine lange interne Denkkette (response["result"]["choices"][0]
        # ["message"]["reasoning_content"]), die selbst schon 1024 Tokens
        # aufbrauchen kann, bevor der eigentliche Tool-Call ueberhaupt beginnt -
        # live beobachtet: bei max_tokens=1024 brach die Antwort mit
        # finish_reason="length" mitten im JSON des Tool-Calls ab, "tool_calls"
        # blieb leer. Cloudflares Workers-AI-Schema fuer dieses Modell bietet
        # (Stand jetzt) keinen Parameter, um die Denkkette abzuschalten - 4096
        # gibt ihr genug Raum, bei weiterhin vernachlaessigbaren Kosten
        # (~$0.34/Mio Output-Tokens).
        max_tokens=4096,
        messages=[{"role": "user", "content": prompt_text}],
        tools=[_tool_schema_openai(catalog_ids)],
    )
    # Cloudflares v4-Standard-Fehlerhuelle bei einem fehlgeschlagenen Aufruf sieht so
    # aus: {"result": None, "success": False, "errors": [{"code": ..., "message": ...}]}.
    # Der Schluessel "result" ist dabei VORHANDEN (nur eben None) - response.get(
    # "result", {}) liefert in diesem Fall also None statt des {}-Defaults (der Default
    # greift nur, wenn der Schluessel fehlt), und ein direktes .get("tool_calls") darauf
    # wuerfe einen unkontrollierten AttributeError statt eines RuntimeError. Diese
    # Pruefung faengt den Fehlerfall vorher ab und reicht Cloudflares eigenen
    # Fehlertext weiter - der bei einem ersten echten Live-Aufruf der mit Abstand
    # nuetzlichste Diagnosewert ist.
    if not response.get("success", True) or response.get("result") is None:
        errors = response.get("errors") or []
        error_text = (
            "; ".join(str(e.get("message", e)) for e in errors) if errors else "unbekannter Fehler"
        )
        raise RuntimeError(f"Cloudflare-Antwort meldete einen Fehler: {error_text}")
    tool_calls = response.get("result", {}).get("tool_calls") or []
    for call in tool_calls:
        # Cloudflare/Workers AI kann tool_calls Berichten/Doku zufolge in zwei Formen
        # liefern: flach ({"name": ..., "arguments": ...}, laut Cloudflares eigenen
        # Beispielen) oder im OpenAI-kompatiblen verschachtelten Format
        # ({"type": "function", "function": {"name": ..., "arguments": ...}},
        # ohne top-level "name"/"arguments"). WICHTIG: keine dieser beiden Formen wurde
        # bisher gegen eine echte Live-Antwort verifiziert (siehe Modul-Docstring oben)
        # - beide werden vorsorglich unterstuetzt, falls die tatsaechliche Form von der
        # einen oder anderen Doku-Annahme abweicht. name/arguments muessen aus
        # BEIDEN Formen aufgeloest werden, bevor der Namensabgleich passiert - sonst
        # wird ein verschachtelter tool_call faelschlich uebersprungen, weil
        # call.get("name") dafuer None ist.
        fn = call.get("function") if isinstance(call.get("function"), dict) else {}
        name = call.get("name") or fn.get("name")
        if name != _TOOL_NAME:
            continue
        arguments = fn.get("arguments", call.get("arguments", {}))
        # Cloudflares eigene Dokumentation deklariert "arguments" als Typ
        # "unknown" - je nach Modell kann es ein bereits geparstes Objekt oder
        # ein JSON-kodierter String sein.
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

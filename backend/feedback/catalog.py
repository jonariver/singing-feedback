"""Laedt und durchsucht den kuratierten Uebungskatalog (exercises/catalog.yaml).
Der Katalog-Kommentar selbst haelt fest: Claude soll bevorzugt aus diesen
Eintraegen waehlen statt Uebungen frei zu erfinden - lookup() ist der Ort, an
dem diese Regel technisch durchgesetzt wird (siehe generate.py)."""

from __future__ import annotations

from pathlib import Path

import yaml

_CATALOG_PATH = Path(__file__).resolve().parent.parent / "exercises" / "catalog.yaml"


def load_catalog(path: Path = _CATALOG_PATH) -> list[dict]:
    """Laedt den Uebungskatalog aus der YAML-Datei. Jeder Eintrag hat mindestens
    id, problem, technik, uebung (siehe exercises/catalog.yaml)."""
    with open(path, encoding="utf-8") as f:
        return yaml.safe_load(f) or []


def catalog_ids(catalog: list[dict]) -> list[str]:
    """Liste aller IDs im Katalog, z.B. fuer ein Enum im Anthropic-Tool-Schema."""
    return [entry["id"] for entry in catalog]


def lookup(catalog: list[dict], exercise_id: str) -> dict | None:
    """Findet einen Katalog-Eintrag per ID, oder None wenn nicht vorhanden."""
    for entry in catalog:
        if entry["id"] == exercise_id:
            return entry
    return None

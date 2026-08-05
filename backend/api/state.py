"""In-memory Session-Speicher fuer geparste MIDI-Objekte.

Bewusst keine Datenbank/Persistenz (siehe Leitplanken): ein Prozessneustart
loescht alles, und Eintraege verfallen zusaetzlich per TTL, falls ein Nutzer
den Tab offen laesst und nie aufraeumt.
"""

from __future__ import annotations

import threading
import time
from typing import Any

_SESSION_TTL_SECONDS = 30 * 60


class _SessionStore:
    def __init__(self, ttl_seconds: float = _SESSION_TTL_SECONDS) -> None:
        self._data: dict[str, tuple[Any, float]] = {}
        self._lock = threading.Lock()
        self._ttl = ttl_seconds

    def set(self, key: str, value: Any) -> None:
        with self._lock:
            self._data[key] = (value, time.time())

    def get(self, key: str) -> Any | None:
        with self._lock:
            entry = self._data.get(key)
            if entry is None:
                return None
            value, created_at = entry
            if time.time() - created_at > self._ttl:
                del self._data[key]
                return None
            return value

    def pop(self, key: str, default: Any = None) -> Any:
        with self._lock:
            entry = self._data.pop(key, None)
            return entry[0] if entry is not None else default


# Ein modulweiter, threading.Lock-geschuetzter Store reicht fuer die MVP-Phase - er ist
# sicher fuer nebenlaeufige Requests *innerhalb eines einzigen Prozesses* (z.B. via
# FastAPIs Threadpool fuer synchrone Routen). Wichtiger Constraint, sobald das Backend
# gehostet statt nur lokal betrieben wird: NICHT mit mehreren Worker-Prozessen starten
# (z.B. "uvicorn --workers N") oder hinter mehreren Instanzen ohne Sticky Sessions -
# eine in Prozess A erzeugte session_id waere fuer Prozess B unsichtbar und wuerde zu
# verwirrenden 404s auf /track-curve bzw. /audio/analyze-Folgecalls fuehren. Persistenz
# ueber mehrere Worker hinweg (z.B. Redis) waere die Loesung, widerspraeche aber dem
# bewussten No-DB-Prinzip - bleibt also eine spaetere Entscheidung, kein aktueller Bug.
MIDI_SESSIONS = _SessionStore()

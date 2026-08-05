"""Einfaches IP-basiertes Rate-Limiting fuer die Upload-Endpunkte.

Bewusst handgerollt statt zusaetzlicher Dependency, im selben Stil wie state.py: das
Backend hat weder Nutzerkonten noch Auth, Upload-Groessenlimits + ein simples
Zeitfenster-Limit pro Client-IP sind die einzigen praktikablen Missbrauchsbremsen, sobald
es nicht mehr nur auf localhost laeuft. Wie bei state.py gilt: der Zaehler lebt nur
im Prozessspeicher eines einzigen Worker-Prozesses (siehe dortige Doku).
"""

from __future__ import annotations

import threading
import time

from fastapi import HTTPException, Request

from backend.config import RATE_LIMIT_MAX_REQUESTS, RATE_LIMIT_WINDOW_SECONDS


class _RateLimiter:
    def __init__(self, max_requests: int, window_seconds: float) -> None:
        self._max_requests = max_requests
        self._window_seconds = window_seconds
        self._hits: dict[str, list[float]] = {}
        self._lock = threading.Lock()

    def check(self, client_key: str) -> None:
        now = time.time()
        with self._lock:
            hits = [t for t in self._hits.get(client_key, []) if now - t < self._window_seconds]
            if len(hits) >= self._max_requests:
                self._hits[client_key] = hits
                raise HTTPException(
                    status_code=429,
                    detail="Zu viele Anfragen - bitte kurz warten und erneut versuchen.",
                )
            hits.append(now)
            self._hits[client_key] = hits


_upload_limiter = _RateLimiter(RATE_LIMIT_MAX_REQUESTS, RATE_LIMIT_WINDOW_SECONDS)


def enforce_upload_rate_limit(request: Request) -> None:
    client_key = request.client.host if request.client else "unknown"
    _upload_limiter.check(client_key)

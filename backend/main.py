"""FastAPI-App: bindet die API-Routen und liefert das statische Frontend aus.

Kein separater Build-Step fuer das Frontend (Vanilla HTML/JS/Canvas), damit der
lokale Start unter Windows so einfach wie moeglich bleibt (siehe run.py).
"""

from pathlib import Path

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles

from backend.api.routes import router as api_router

FRONTEND_DIR = Path(__file__).resolve().parent.parent / "frontend"

app = FastAPI(title="Singing Feedback MVP")
app.include_router(api_router)

# Muss nach den API-Routen gemountet werden: der Root-Mount faengt sonst alles ab.
app.mount("/", StaticFiles(directory=FRONTEND_DIR, html=True), name="frontend")

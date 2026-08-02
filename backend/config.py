"""Zentrale Konfiguration. Laedt .env, damit z.B. ANTHROPIC_API_KEY nie im Frontend
landet und nur hier (serverseitig) gelesen wird."""

import os
from pathlib import Path

from dotenv import load_dotenv

PROJECT_ROOT = Path(__file__).resolve().parent.parent
load_dotenv(PROJECT_ROOT / ".env")

ANTHROPIC_API_KEY = os.environ.get("ANTHROPIC_API_KEY", "")
ANTHROPIC_MODEL = os.environ.get("ANTHROPIC_MODEL", "claude-sonnet-5")

# Kurze Ausschnitte zuerst (siehe Plan): 20-60s.
MAX_AUDIO_SECONDS = 90

# Plausibler menschlicher Gesangsumfang fuer Pitch-Erkennung (Phase 1: fixe Grenzen,
# spaetere Phasen koennten das je nach erkannter MIDI-Spur enger fassen).
PITCH_FMIN_HZ = 65.0   # ~C2
PITCH_FMAX_HZ = 1050.0  # ~C6

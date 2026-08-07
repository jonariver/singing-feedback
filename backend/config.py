"""Zentrale Konfiguration. Laedt .env, damit z.B. ANTHROPIC_API_KEY nie im Frontend
landet und nur hier (serverseitig) gelesen wird."""

import os
from pathlib import Path

from dotenv import load_dotenv

PROJECT_ROOT = Path(__file__).resolve().parent.parent
load_dotenv(PROJECT_ROOT / ".env")

ANTHROPIC_API_KEY = os.environ.get("ANTHROPIC_API_KEY", "")
ANTHROPIC_MODEL = os.environ.get("ANTHROPIC_MODEL", "claude-sonnet-5")

# Komma-getrennte Liste erlaubter Origins fuers CORS, z.B. wenn das Backend
# gehostet und von einer Mobile-App oder einem separat gehosteten Frontend
# aus angesprochen wird. Leer = keine Cross-Origin-Requests erlaubt (Default,
# passt zum lokalen Same-Origin-Betrieb via run.py).
CORS_ALLOWED_ORIGINS = [
    origin.strip()
    for origin in os.environ.get("CORS_ALLOWED_ORIGINS", "").split(",")
    if origin.strip()
]

# Kurze Ausschnitte zuerst (siehe Plan): 20-60s.
MAX_AUDIO_SECONDS = 90

# Rate-Limiting fuer die Upload-Endpunkte (siehe api/rate_limit.py): ohne Nutzerkonten/Auth
# sind Upload-Groessenlimits + ein simples Zeitfenster-Limit pro Client-IP die einzigen
# praktikablen Missbrauchsbremsen, sobald das Backend nicht mehr nur auf localhost laeuft.
RATE_LIMIT_MAX_REQUESTS = int(os.environ.get("RATE_LIMIT_MAX_REQUESTS", "20"))
RATE_LIMIT_WINDOW_SECONDS = float(os.environ.get("RATE_LIMIT_WINDOW_SECONDS", "60"))

# Plausibler menschlicher Gesangsumfang fuer Pitch-Erkennung (Phase 1: fixe Grenzen,
# spaetere Phasen koennten das je nach erkannter MIDI-Spur enger fassen).
PITCH_FMIN_HZ = 65.0   # ~C2
PITCH_FMAX_HZ = 1050.0  # ~C6

# Bewertungs-Engine (Phase 4): Noten-Segmentierung aus der Zielkurve (kein
# MIDI_SESSIONS-Zugriff, siehe Design-Spec docs/superpowers/specs/2026-08-06-scoring-engine-design.md).
NOTE_SEGMENT_TOLERANCE_CENTS = 50.0
NOTE_SEGMENT_ROLLING_WINDOW_FRAMES = 30
NOTE_SEGMENT_MAX_BRIDGE_GAP_FRAMES = 15
NOTE_SEGMENT_MIN_DURATION_SECONDS = 0.12

# Bewertungs-Engine: Zurechnung gesungener Frames zu Noten.
LAST_NOTE_TAIL_TOLERANCE_SECONDS = 0.3

# Bewertungs-Engine: Cent-Abweichung & verfehlte Zielnoten.
CENTS_GREEN_THRESHOLD = 15.0
CENTS_YELLOW_THRESHOLD = 50.0
MISSED_NOTE_MIN_COVERAGE_FRACTION = 0.5
MISSED_NOTE_CENTS_THRESHOLD = 300.0
STABILITY_ONSET_TRIM_SECONDS = 0.05

# Bewertungs-Engine: Timing (fruehe/spaete Einsaetze).
TIMING_ONSET_WINDOW_FRAMES = 5
TIMING_OK_THRESHOLD_MS = 60.0
TIMING_MAX_SEARCH_SECONDS = 1.0

# Bewertungs-Engine: Stabilitaet & Phrasenend-Drift bei gehaltenen Toenen.
HELD_NOTE_MIN_DURATION_SECONDS = 0.6
STABILITY_MAD_THRESHOLD_CENTS = 25.0
DRIFT_TAIL_SECONDS = 0.3
DRIFT_FLAG_THRESHOLD_CENTS = 30.0

# Bewertungs-Engine: Glide-Erkennung (Phase 4-Rest, Teil 1) - siehe
# docs/superpowers/specs/2026-08-07-glide-detection-design.md.
GLIDE_HEAD_SECONDS = 0.15
GLIDE_MIN_HEAD_FRAMES = 3
GLIDE_ONSET_THRESHOLD_CENTS = 60.0

# Groessenschutz fuer POST /api/score (kein Audio-Upload -> MAX_AUDIO_SECONDS greift
# hier nicht automatisch, da ein Client theoretisch ein ueberlanges JSON-Array direkt
# posten koennte, ohne ueber /api/audio/analyze bzw. /api/sync/align gegangen zu sein).
MAX_SCORE_CURVE_FRAMES = 20000  # ~200s bei 100Hz, grosszuegig ueber MAX_AUDIO_SECONDS

MAX_SCORE_REQUEST_BYTES = 20 * 1024 * 1024  # grosszuegig ueber dem realistischen JSON-Volumen bei MAX_SCORE_CURVE_FRAMES

# DTW-Ausrichtung (Phase 3): Sakoe-Chiba-Bandradius, um den Ausrichtungspfad nah an
# der Diagonale zu halten. Ohne Begrenzung kann der Pfad in laengeren, echten
# Aufnahmen mit Pausen/stillen Abschnitten (wenig Onset-Signal als Kostendruck)
# beliebig weit "wegdriften" - real beobachtet: bis zu 18.7s Verschiebung auf einer
# 61s-Aufnahme mit 20s Stille (siehe docs/superpowers/specs/2026-08-06-dtw-drift-band-fix-design.md).
# Bruchteil der kuerzeren Kurvenlaenge (radius_frames = round(band_rad * min(len(X), len(Y)))
# per librosa.sequence.dtw), skaliert also automatisch mit der Aufnahmedauer. librosa
# erweitert das Band zusaetzlich um |len(X) - len(Y)|, wenn die beiden Kurven
# unterschiedlich lang sind.
DTW_BAND_RADIUS = 0.1

# Spurerkennung (Phase 2): Gewichteter Score je Kandidat (0-100), ersetzt die reine
# Tuple-Sortierung aus Phase 1. Siehe
# docs/superpowers/specs/2026-08-07-track-scoring-and-preview-design.md.
TRACK_SCORE_VOCAL_RANGE_MIDI_MIN = 43  # ~G2, grosszuegige untere Grenze
TRACK_SCORE_VOCAL_RANGE_MIDI_MAX = 84  # ~C6, grosszuegige obere Grenze
TRACK_SCORE_DENSITY_MIN_NOTES_PER_SEC = 0.5
TRACK_SCORE_DENSITY_MAX_NOTES_PER_SEC = 4.0
TRACK_SCORE_DURATION_RATIO_FULL_SCORE = 0.3  # ab 30% der laengsten Spur volle Punktzahl

# Spurerkennung: Hoerprobe (Sinus-/Obertonsynthesizer, kein Soundfont - siehe PLAN.md).
TRACK_PREVIEW_MAX_SECONDS = 15.0
TRACK_PREVIEW_SAMPLE_RATE = 22050

"""Synchronisation von Gesangsaufnahme und Zielmelodie (DTW, Phase 3)."""

from .align import MAX_DURATION_RATIO, align_curves, duration_ratio_exceeds_limit
from .features import onset_envelope_from_midi_track, onset_envelope_from_signal

__all__ = [
    "MAX_DURATION_RATIO",
    "align_curves",
    "duration_ratio_exceeds_limit",
    "onset_envelope_from_midi_track",
    "onset_envelope_from_signal",
]

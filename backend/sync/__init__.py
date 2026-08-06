"""Synchronisation von Gesangsaufnahme und Zielmelodie (DTW, Phase 3)."""

from .align import align_curves
from .features import onset_envelope_from_midi_track, onset_envelope_from_signal

__all__ = ["align_curves", "onset_envelope_from_midi_track", "onset_envelope_from_signal"]

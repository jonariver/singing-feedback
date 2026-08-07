"""Bewertungs-Engine: Cent-Abweichung, verfehlte Zielnoten, Timing, Stabilitaet,
Phrasenend-Drift (Phase 4, Kernpaket). Pausen/Atemstellen folgt spaeter.
"""

from .notes import segment_target_notes
from .score import score_performance

__all__ = ["score_performance", "segment_target_notes"]

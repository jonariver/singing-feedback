"""Bewertungs-Engine: Cent-Abweichung, verfehlte Zielnoten, Timing, Stabilitaet,
Phrasenend-Drift (Phase 4, Kernpaket), sowie Glides, Stimmumfang und
Pausen/Atemstellen (Phase 4-Rest).
"""

from .notes import segment_target_notes
from .score import score_performance

__all__ = ["score_performance", "segment_target_notes"]

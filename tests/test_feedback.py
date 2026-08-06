"""Tests fuer das Feedback-Modul (Phase 6)."""

from __future__ import annotations

from backend.feedback.catalog import catalog_ids, load_catalog, lookup
from backend.feedback.prompt import build_prompt_context, build_prompt_text


def test_load_catalog_returns_list_of_entries(tmp_path):
    catalog_file = tmp_path / "catalog.yaml"
    catalog_file.write_text(
        "- id: test_id\n  problem: Testproblem\n  technik: Testtechnik\n  uebung: Testuebung\n",
        encoding="utf-8",
    )
    catalog = load_catalog(catalog_file)
    assert catalog == [
        {"id": "test_id", "problem": "Testproblem", "technik": "Testtechnik", "uebung": "Testuebung"}
    ]


def test_catalog_ids_extracts_all_ids():
    catalog = [{"id": "a", "problem": "P"}, {"id": "b", "problem": "Q"}]
    assert catalog_ids(catalog) == ["a", "b"]


def test_lookup_finds_entry_by_id():
    catalog = [{"id": "a", "problem": "P"}, {"id": "b", "problem": "Q"}]
    assert lookup(catalog, "b") == {"id": "b", "problem": "Q"}


def test_lookup_returns_none_for_unknown_id():
    catalog = [{"id": "a", "problem": "P"}]
    assert lookup(catalog, "nonexistent") is None


def _note(
    index: int,
    missed: bool = False,
    cents_classification: str = "green",
    cents_value: float | None = 0.0,
    timing_classification: str = "on_time",
    timing_deviation_ms: float | None = None,
    stability_flag: bool = False,
    drift_flag: bool = False,
    drift_direction: str | None = None,
) -> dict:
    return {
        "index": index,
        "start_t": index * 1.0,
        "end_t": index * 1.0 + 1.0,
        "target_hz": 440.0,
        "target_midi_note": 69,
        "missed": missed,
        "coverage_fraction": 0.0 if missed else 1.0,
        "cents_deviation": {"value": cents_value, "classification": cents_classification},
        "timing": {"deviation_ms": timing_deviation_ms, "classification": timing_classification},
        "held": False,
        "stability": {"applicable": True, "mad_cents": 0.0, "flag": stability_flag},
        "phrase_end_drift": {
            "applicable": True,
            "drift_cents": 0.0,
            "flag": drift_flag,
            "direction": drift_direction,
        },
    }


def _score_result(notes: list[dict]) -> dict:
    return {
        "notes": notes,
        "summary": {
            "note_count": len(notes),
            "missed_count": sum(1 for n in notes if n["missed"]),
            "cents_green": sum(1 for n in notes if n["cents_deviation"]["classification"] == "green"),
            "cents_yellow": sum(1 for n in notes if n["cents_deviation"]["classification"] == "yellow"),
            "cents_red": sum(1 for n in notes if n["cents_deviation"]["classification"] == "red"),
            "timing_flagged_count": sum(1 for n in notes if n["timing"]["classification"] != "on_time"),
            "stability_flagged_count": sum(1 for n in notes if n["stability"]["flag"]),
            "phrase_end_drift_flagged_count": sum(1 for n in notes if n["phrase_end_drift"]["flag"]),
            "overall_score": 100.0,
            "problem_tags": [],
        },
    }


def test_build_prompt_context_filters_out_unflagged_notes():
    notes = [
        _note(0),
        _note(1, missed=True),
        _note(2, cents_classification="red", cents_value=120.0),
        _note(3, timing_classification="too_late", timing_deviation_ms=250.0),
        _note(4, stability_flag=True),
        _note(5, drift_flag=True, drift_direction="down"),
    ]
    context = build_prompt_context(_score_result(notes))
    flagged_indices = [n["index"] for n in context["flagged_notes"]]
    assert flagged_indices == [1, 2, 3, 4, 5]


def test_build_prompt_context_includes_summary_unchanged():
    notes = [_note(0, missed=True)]
    score_result = _score_result(notes)
    context = build_prompt_context(score_result)
    assert context["summary"] == score_result["summary"]


def test_build_prompt_text_mentions_key_summary_numbers():
    notes = [_note(0, missed=True)]
    context = build_prompt_context(_score_result(notes))
    text = build_prompt_text(context)
    assert "Verfehlte Noten: 1" in text
    assert "Note 1:" in text
    assert "verfehlt" in text


def test_build_prompt_text_says_keine_when_no_flagged_notes():
    notes = [_note(0)]
    context = build_prompt_context(_score_result(notes))
    text = build_prompt_text(context)
    assert "- keine" in text

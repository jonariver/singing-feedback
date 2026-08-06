"""Tests fuer das Feedback-Modul (Phase 6)."""

from __future__ import annotations

from types import SimpleNamespace

import pytest

from backend.feedback.catalog import catalog_ids, load_catalog, lookup
from backend.feedback.client import request_feedback_points
from backend.feedback.generate import FeedbackUnavailableError, generate_feedback
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


def test_build_prompt_context_caps_flagged_notes_at_50():
    notes = [_note(i, missed=True) for i in range(60)]
    context = build_prompt_context(_score_result(notes))
    assert len(context["flagged_notes"]) == 50


class _FakeMessagesClient:
    def __init__(self, points=None, raise_error=None):
        self._points = points if points is not None else []
        self._raise_error = raise_error
        self.last_kwargs = None

    def create(self, **kwargs):
        self.last_kwargs = kwargs
        if self._raise_error:
            raise self._raise_error
        block = SimpleNamespace(
            type="tool_use", name="return_feedback_points", input={"points": self._points}
        )
        return SimpleNamespace(content=[block])


def test_request_feedback_points_extracts_points_from_tool_use_block():
    fake = _FakeMessagesClient(points=[{"problem": "P", "uebung_id": "a"}])
    points = request_feedback_points(fake, "claude-sonnet-5", "prompt", ["a"])
    assert points == [{"problem": "P", "uebung_id": "a"}]


def test_request_feedback_points_passes_catalog_ids_as_enum_in_tool_schema():
    fake = _FakeMessagesClient(points=[])
    request_feedback_points(fake, "claude-sonnet-5", "prompt", ["a", "b"])
    schema = fake.last_kwargs["tools"][0]["input_schema"]
    assert schema["properties"]["points"]["items"]["properties"]["uebung_id"]["enum"] == ["a", "b"]


def test_request_feedback_points_raises_when_no_tool_use_block_present():
    class _NoToolUseClient:
        def create(self, **kwargs):
            return SimpleNamespace(content=[SimpleNamespace(type="text", name=None, input=None)])

    with pytest.raises(RuntimeError):
        request_feedback_points(_NoToolUseClient(), "claude-sonnet-5", "prompt", ["a"])


def _score_result_with_tags(problem_tags: list[str]) -> dict:
    notes = [_note(0, missed=bool(problem_tags))] if problem_tags else []
    result = _score_result(notes)
    result["summary"]["problem_tags"] = problem_tags
    return result


def test_generate_feedback_returns_empty_points_without_api_call_when_no_problem_tags():
    calls = []

    def factory():
        calls.append(1)
        return _FakeMessagesClient(points=[])

    result = generate_feedback(_score_result_with_tags([]), messages_client_factory=factory)
    assert result == {"points": []}
    assert calls == []


def test_generate_feedback_raises_when_api_key_missing(monkeypatch):
    monkeypatch.setattr("backend.feedback.generate.ANTHROPIC_API_KEY", "")
    with pytest.raises(FeedbackUnavailableError):
        generate_feedback(
            _score_result_with_tags(["timingprobleme"]),
            messages_client_factory=lambda: _FakeMessagesClient(),
        )


def test_generate_feedback_enriches_points_with_catalog_text(monkeypatch):
    monkeypatch.setattr("backend.feedback.generate.ANTHROPIC_API_KEY", "dummy-key")
    fake = _FakeMessagesClient(points=[{"problem": "Timing daneben", "uebung_id": "timingprobleme"}])
    result = generate_feedback(
        _score_result_with_tags(["timingprobleme"]), messages_client_factory=lambda: fake
    )
    expected_entry = lookup(load_catalog(), "timingprobleme")
    assert result["points"] == [{
        "problem": "Timing daneben",
        "technik": expected_entry["technik"],
        "uebung": expected_entry["uebung"],
        "wiederholungsaufgabe": None,
    }]


def test_generate_feedback_drops_points_with_unknown_uebung_id(monkeypatch):
    monkeypatch.setattr("backend.feedback.generate.ANTHROPIC_API_KEY", "dummy-key")
    fake = _FakeMessagesClient(points=[{"problem": "X", "uebung_id": "nicht_im_katalog"}])
    result = generate_feedback(
        _score_result_with_tags(["timingprobleme"]), messages_client_factory=lambda: fake
    )
    assert result["points"] == []


def test_generate_feedback_raises_when_anthropic_call_fails(monkeypatch):
    monkeypatch.setattr("backend.feedback.generate.ANTHROPIC_API_KEY", "dummy-key")
    fake = _FakeMessagesClient(raise_error=RuntimeError("boom"))
    with pytest.raises(FeedbackUnavailableError):
        generate_feedback(
            _score_result_with_tags(["timingprobleme"]), messages_client_factory=lambda: fake
        )

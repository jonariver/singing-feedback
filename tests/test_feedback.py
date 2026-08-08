"""Tests fuer das Feedback-Modul (Phase 6)."""

from __future__ import annotations

from types import SimpleNamespace

import pytest

from backend.feedback.catalog import catalog_ids, load_catalog, lookup
from backend.feedback.client import request_feedback_points
from backend.feedback.generate import _CATEGORY_MATCHERS, FeedbackUnavailableError, generate_feedback
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


def test_category_matchers_cover_exactly_the_real_catalog_ids():
    # Verhindert, dass ein Tippfehler in _CATEGORY_MATCHERS oder im Katalog still
    # _find_jump_to_t fuer eine Kategorie (z.B. Pause) auf None zurueckfallen laesst,
    # ohne dass ein Test das bemerkt.
    assert set(_CATEGORY_MATCHERS) == set(catalog_ids(load_catalog()))


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
    glide_flag: bool = False,
    glide_direction: str | None = None,
    pause_flag: bool = False,
    pause_gap_seconds: float = 0.0,
    sung_t: float | None = None,
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
        "glide": {
            "applicable": True,
            "onset_cents_deviation": 0.0,
            "flag": glide_flag,
            "direction": glide_direction,
        },
        "pause": {"applicable": True, "gap_seconds": pause_gap_seconds, "flag": pause_flag},
        "sung_t": sung_t,
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
            "glide_flagged_count": sum(1 for n in notes if n["glide"]["flag"]),
            "pause_flagged_count": sum(1 for n in notes if n["pause"]["flag"]),
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
        _note(6, glide_flag=True, glide_direction="up"),
        _note(7, pause_flag=True),
    ]
    context = build_prompt_context(_score_result(notes))
    flagged_indices = [n["index"] for n in context["flagged_notes"]]
    assert flagged_indices == [1, 2, 3, 4, 5, 6, 7]


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


def test_build_prompt_text_mentions_glide():
    notes = [_note(0, glide_flag=True, glide_direction="up")]
    context = build_prompt_context(_score_result(notes))
    text = build_prompt_text(context)
    assert "Hineingleiten in den Zielton: 1 Noten" in text
    assert "rutscht rein (up)" in text


def test_build_prompt_text_mentions_pause():
    notes = [_note(0, pause_flag=True, pause_gap_seconds=0.34)]
    context = build_prompt_context(_score_result(notes))
    text = build_prompt_text(context)
    assert "Pause mitten in gehaltener Note: 1 Noten" in text
    assert "Pause mitten in der Note (0.34s)" in text


def test_build_prompt_text_says_keine_when_no_flagged_notes():
    notes = [_note(0)]
    context = build_prompt_context(_score_result(notes))
    text = build_prompt_text(context)
    assert "- keine" in text


def test_build_prompt_context_caps_flagged_notes_at_150():
    notes = [_note(i, missed=True) for i in range(200)]
    context = build_prompt_context(_score_result(notes))
    assert len(context["flagged_notes"]) == 150


def test_build_prompt_context_samples_evenly_across_the_whole_song_when_capped():
    # 200 auffaellige Noten ueber einen langen Song verteilt - ohne Sampling wuerde
    # ein chronologischer Prefix von 150 nur die erste dreiviertel Songdauer zeigen
    # und Noten 150-199 (die letzten ~25%) komplett aus dem Prompt fallen lassen.
    notes = [_note(i, missed=True) for i in range(200)]
    context = build_prompt_context(_score_result(notes))
    flagged_indices = [n["index"] for n in context["flagged_notes"]]
    assert flagged_indices[0] == 0
    assert flagged_indices[-1] == 199
    # Ueberpruef, dass die Auswahl wirklich ueber die ganze Spanne gestreut ist statt
    # geklumpt zu sein: kein Abstand zwischen benachbarten ausgewaehlten Noten darf
    # groesser als 2x der erwarteten mittleren Schrittweite (200 Noten / 150 Auswahl)
    # sein.
    expected_step = 199 / 149
    max_gap = max(b - a for a, b in zip(flagged_indices, flagged_indices[1:]))
    assert max_gap <= expected_step * 2


def test_build_prompt_context_carries_sung_t_through():
    notes = [_note(0, missed=True, sung_t=12.5)]
    context = build_prompt_context(_score_result(notes))
    assert context["flagged_notes"][0]["sung_t"] == 12.5


def test_build_prompt_context_flagged_note_sung_t_can_be_none():
    notes = [_note(0, missed=True, sung_t=None)]
    context = build_prompt_context(_score_result(notes))
    assert context["flagged_notes"][0]["sung_t"] is None


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
        "jump_to_t": None,
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


def test_generate_feedback_includes_jump_to_t_from_first_matching_note(monkeypatch):
    monkeypatch.setattr("backend.feedback.generate.ANTHROPIC_API_KEY", "dummy-key")
    notes = [
        _note(0, timing_classification="too_late", timing_deviation_ms=100.0, sung_t=5.0),
        _note(1, timing_classification="too_late", timing_deviation_ms=120.0, sung_t=9.0),
    ]
    score_result = _score_result(notes)
    score_result["summary"]["problem_tags"] = ["timingprobleme"]
    fake = _FakeMessagesClient(points=[{"problem": "Timing", "uebung_id": "timingprobleme"}])
    result = generate_feedback(score_result, messages_client_factory=lambda: fake)
    assert result["points"][0]["jump_to_t"] == 5.0


def test_generate_feedback_skips_notes_without_sung_t_when_finding_jump_target(monkeypatch):
    monkeypatch.setattr("backend.feedback.generate.ANTHROPIC_API_KEY", "dummy-key")
    notes = [
        _note(0, missed=True, sung_t=None),
        _note(1, missed=True, sung_t=7.5),
    ]
    score_result = _score_result(notes)
    score_result["summary"]["problem_tags"] = ["unsaubere_einsaetze"]
    fake = _FakeMessagesClient(points=[{"problem": "Verfehlt", "uebung_id": "unsaubere_einsaetze"}])
    result = generate_feedback(score_result, messages_client_factory=lambda: fake)
    assert result["points"][0]["jump_to_t"] == 7.5


def test_generate_feedback_gives_different_notes_to_two_points_of_the_same_category(monkeypatch):
    monkeypatch.setattr("backend.feedback.generate.ANTHROPIC_API_KEY", "dummy-key")
    notes = [
        _note(0, stability_flag=True, sung_t=1.0),
        _note(1, stability_flag=True, sung_t=2.0),
    ]
    score_result = _score_result(notes)
    score_result["summary"]["problem_tags"] = ["instabile_lange_toene"]
    fake = _FakeMessagesClient(points=[
        {"problem": "A", "uebung_id": "instabile_lange_toene"},
        {"problem": "B", "uebung_id": "instabile_lange_toene"},
    ])
    result = generate_feedback(score_result, messages_client_factory=lambda: fake)
    assert result["points"][0]["jump_to_t"] == 1.0
    assert result["points"][1]["jump_to_t"] == 2.0


def test_generate_feedback_glide_category_resolves_jump_to_t(monkeypatch):
    # Vor dieser Aenderung hatte "haeufiges_hineingleiten" keinen Eintrag in
    # _CATEGORY_MATCHERS - _find_jump_to_t haette hier immer None zurueckgegeben,
    # unabhaengig von sung_t.
    monkeypatch.setattr("backend.feedback.generate.ANTHROPIC_API_KEY", "dummy-key")
    notes = [_note(0, glide_flag=True, glide_direction="up", sung_t=3.5)]
    score_result = _score_result(notes)
    score_result["summary"]["problem_tags"] = ["haeufiges_hineingleiten"]
    fake = _FakeMessagesClient(
        points=[{"problem": "Rutscht in den Ton", "uebung_id": "haeufiges_hineingleiten"}]
    )
    result = generate_feedback(score_result, messages_client_factory=lambda: fake)
    assert result["points"][0]["jump_to_t"] == 3.5


def test_generate_feedback_pause_category_resolves_jump_to_t(monkeypatch):
    monkeypatch.setattr("backend.feedback.generate.ANTHROPIC_API_KEY", "dummy-key")
    notes = [_note(0, pause_flag=True, sung_t=5.2)]
    score_result = _score_result(notes)
    score_result["summary"]["problem_tags"] = ["unerwartete_pause_in_gehaltener_note"]
    fake = _FakeMessagesClient(
        points=[{
            "problem": "Atempause mitten im Ton",
            "uebung_id": "unerwartete_pause_in_gehaltener_note",
        }]
    )
    result = generate_feedback(score_result, messages_client_factory=lambda: fake)
    assert result["points"][0]["jump_to_t"] == 5.2


def test_generate_feedback_jump_to_t_is_none_when_no_note_matches(monkeypatch):
    monkeypatch.setattr("backend.feedback.generate.ANTHROPIC_API_KEY", "dummy-key")
    notes = [_note(0, missed=True, sung_t=3.0)]
    score_result = _score_result(notes)
    score_result["summary"]["problem_tags"] = ["absinkende_phrasenenden"]
    fake = _FakeMessagesClient(points=[{"problem": "X", "uebung_id": "absinkende_phrasenenden"}])
    result = generate_feedback(score_result, messages_client_factory=lambda: fake)
    assert result["points"][0]["jump_to_t"] is None

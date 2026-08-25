"""Tests for the parts of the harness that decide what gets paid for.

The expensive parts of this benchmark are network calls, and they are not tested
here. What is tested is everything that decides *which* calls happen and how a
finished call is counted, because a mistake there is not a crash — it is a
plausible-looking number that cost money to produce and cannot be recomputed.
"""

from __future__ import annotations

import asyncio
import json
import sys
from pathlib import Path

import pytest

BENCH = Path(__file__).resolve().parents[1]
if str(BENCH) not in sys.path:
    sys.path.insert(0, str(BENCH))

from harness import catalog, dataset, runner  # noqa: E402

POOL = BENCH.parent / "vsr" / "pool.yaml"


def member(name: str, alias: str, limit: int | None = None) -> catalog.Member:
    return catalog.Member(
        name=name,
        alias=alias,
        transport="bedrock",
        pricing_key=alias,
        prompt_per_1m=1.0,
        completion_per_1m=2.0,
        roles=("member",),
        region="us-east-1",
        priced_as_measured=True,
        max_concurrent_sequences=limit,
    )


def item(question_id: str) -> dataset.Item:
    return dataset.Item(
        question_id=question_id,
        dataset="MMLU-Pro",
        category="math",
        fold="test",
        prompt="q",
        question={"answer": "A"},
    )


class TestArmExpansion:
    def test_pool_declarations_are_used(self):
        arms = catalog.arms(POOL, [member("sclv/gpt-5.6-sol", "gpt-5.6-sol")])
        assert [a.effort for a in arms] == ["default", "none", "low", "high"]
        assert [a.name for a in arms] == [
            "sclv/gpt-5.6-sol",
            "sclv/gpt-5.6-sol@none",
            "sclv/gpt-5.6-sol@low",
            "sclv/gpt-5.6-sol@high",
        ]

    def test_an_undeclared_member_gets_the_default_level_only(self):
        """Adding a member must never silently multiply a run's price."""
        arms = catalog.arms(POOL, [member("sclv/claude-opus-5", "claude-opus-5")])
        assert [a.effort for a in arms] == ["default"]
        assert arms[0].name == "sclv/claude-opus-5"

    def test_the_default_level_omits_the_field(self):
        """"No reasoning_effort" is a setting, and the only one the whole pool takes."""
        arms = catalog.arms(POOL, [member("sclv/grok-4.6", "grok-4.6")])
        by_effort = {a.effort: a.request_effort for a in arms}
        assert by_effort["default"] is None
        assert by_effort["high"] == "high"

    def test_duplicate_levels_are_collapsed(self, tmp_path):
        pool = tmp_path / "pool.yaml"
        pool.write_text("effort_levels:\n  m: [default, low, low, default]\n")
        arms = catalog.arms(pool, [member("sclv/m", "m")])
        assert [a.effort for a in arms] == ["default", "low"]


class TestTasks:
    def test_one_task_per_arm_and_question_carrying_the_effort(self):
        arms = catalog.arms(POOL, [member("sclv/gpt-5.6-sol", "gpt-5.6-sol")])
        tasks = runner.pinned_tasks([item("1"), item("2")], arms)
        assert len(tasks) == 8
        one = next(t for t in tasks if t.arm == "pinned:sclv/gpt-5.6-sol@high")
        assert one.model == "sclv/gpt-5.6-sol"
        assert one.effort == "high"
        default = next(t for t in tasks if t.arm == "pinned:sclv/gpt-5.6-sol")
        assert default.effort is None

    def test_arms_of_one_member_share_that_member_s_gate(self):
        """The in-flight limit belongs to the serving member, not to the arm."""
        arms = catalog.arms(POOL, [member("sclv/gpt-5.6-sol", "gpt-5.6-sol")])
        models = {t.model for t in runner.pinned_tasks([item("1")], arms)}
        assert models == {"sclv/gpt-5.6-sol"}

    def test_resume_skips_by_arm_and_question(self, tmp_path):
        out = tmp_path / "matrix.jsonl"
        out.write_text(
            json.dumps({"arm": "pinned:m@low", "question_id": "1"}) + "\n"
        )
        done = runner.completed_cells(out)
        tasks = [
            runner.Task(arm="pinned:m@low", model="m", item=item("1"), effort="low"),
            runner.Task(arm="pinned:m@high", model="m", item=item("1"), effort="high"),
        ]
        remaining = runner.plan(tasks, seed=1, skip=done)
        assert [t.arm for t in remaining] == ["pinned:m@high"]


class TestTruncationRates:
    def test_only_scored_rows_count_and_length_is_the_numerator(self, tmp_path):
        out = tmp_path / "matrix.jsonl"
        rows = [
            {"arm": "a", "finish_reason": "stop", "error": None},
            {"arm": "a", "finish_reason": "length", "error": None},
            {"arm": "a", "finish_reason": "length", "error": None},
            {"arm": "a", "finish_reason": None, "error": "http 502"},
            {"arm": "b", "finish_reason": "stop", "error": None},
        ]
        out.write_text("\n".join(json.dumps(r) for r in rows) + "\n")
        rates = runner.truncation_rates(out)
        assert rates["a"]["scored"] == 3
        assert rates["a"]["rate"] == pytest.approx(2 / 3)
        assert rates["b"]["rate"] == 0.0

    def test_a_missing_file_is_not_an_error(self, tmp_path):
        assert runner.truncation_rates(tmp_path / "nope.jsonl") == {}


class _Response:
    """Enough of a Call for the runner to route it, from a scripted outcome."""

    def __init__(self, arm: str, *, unsupported: bool = False):
        self.arm = arm
        self.arm_unsupported = unsupported
        self.error = "http 400: reasoning_effort" if unsupported else None
        self.text = "Answer: A"
        self.correct = None
        self.extracted = None

    def to_json(self):
        return {"arm": self.arm, "arm_unsupported": self.arm_unsupported}


class TestArmRetirement:
    """A rejected effort level means the arm is gone, not that a question failed."""

    def run_with(self, tmp_path, monkeypatch, reject: set[str], tasks, concurrency=1):
        calls: list[str] = []

        async def fake_call_once(session, url, **kwargs):
            arm = kwargs["arm"]
            calls.append(arm)
            # Suspends, so the other tasks reach the queue while this one is in
            # flight. Without it every fake call would complete before the next
            # task started and the test would pass on a scheduling accident.
            await asyncio.sleep(0)
            return _Response(arm, unsupported=arm in reject)

        class _Graded:
            extracted, correct, parsed = "A", True, True

        monkeypatch.setattr(runner.client, "call_once", fake_call_once)
        monkeypatch.setattr(runner.score, "grade", lambda *a, **k: _Graded())
        config = runner.RunConfig(
            url="http://router",
            max_tokens=16,
            temperature=None,
            concurrency=concurrency,
            max_attempts=1,
            timeout_s=1.0,
            shuffle_seed=1,
        )
        stats = asyncio.run(runner.run(tasks, config, tmp_path / "out.jsonl"))
        return stats, calls

    def test_the_rest_of_a_rejected_arm_is_not_paid_for(self, tmp_path, monkeypatch):
        tasks = [
            runner.Task(arm="pinned:m@high", model="m", item=item(str(i)), effort="high")
            for i in range(5)
        ]
        stats, calls = self.run_with(tmp_path, monkeypatch, {"pinned:m@high"}, tasks)
        assert len(calls) == 1
        assert stats.skipped == 4
        assert "pinned:m@high" in stats.retired_arms

    def test_only_the_calls_in_flight_are_wasted(self, tmp_path, monkeypatch):
        """The bound on waste is the concurrency, and it is not zero."""
        tasks = [
            runner.Task(arm="pinned:m@high", model="m", item=item(str(i)), effort="high")
            for i in range(12)
        ]
        stats, calls = self.run_with(
            tmp_path, monkeypatch, {"pinned:m@high"}, tasks, concurrency=4
        )
        assert 1 <= len(calls) <= 4
        assert stats.skipped == 12 - len(calls)

    def test_retiring_one_arm_leaves_the_others_running(self, tmp_path, monkeypatch):
        tasks = [
            runner.Task(arm=arm, model="m", item=item(str(i)), effort=None)
            for i in range(3)
            for arm in ("pinned:m@high", "pinned:m")
        ]
        stats, calls = self.run_with(tmp_path, monkeypatch, {"pinned:m@high"}, tasks)
        assert calls.count("pinned:m") == 3
        assert calls.count("pinned:m@high") == 1
        assert list(stats.retired_arms) == ["pinned:m@high"]


class TestStreamingDefault:
    def test_streaming_is_on_unless_asked_otherwise(self):
        """The gateway cuts a non-streaming read at 50s, which deletes the high arms."""
        config = runner.RunConfig(
            url="http://router",
            max_tokens=16,
            temperature=None,
            concurrency=1,
            max_attempts=1,
            timeout_s=1.0,
            shuffle_seed=1,
        )
        assert config.stream is True

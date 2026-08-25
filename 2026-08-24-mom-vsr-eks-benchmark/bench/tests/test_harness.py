"""Tests for the parts of the harness that decide what gets paid for.

The expensive parts of this benchmark are network calls, and they are not tested
here. What is tested is everything that decides *which* calls happen, what each one
asks for, and how a finished call is counted — because a mistake there is not a
crash. It is a plausible-looking number that cost money to produce and cannot be
recomputed without spending again.

Two properties are worth stating as the things these cases exist to protect:

* **Comparability.** Every arm must be asked the same question the same way, with
  only its own configuration differing. A regression that quietly sends every arm at
  the default effort, or mixes two completion budgets into one file, produces a
  matrix that looks fine and answers a different question than the one asked.
* **Money.** A call that cannot produce a usable answer must not be made, and one
  that has already been billed must not be paid for twice.
"""

from __future__ import annotations

import asyncio
import json
import sys
from pathlib import Path

import numpy as np
import pytest

BENCH = Path(__file__).resolve().parents[1]
if str(BENCH) not in sys.path:
    sys.path.insert(0, str(BENCH))

import collect  # noqa: E402
import power  # noqa: E402
from harness import catalog, client, dataset, quality, runner  # noqa: E402

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


def config(**overrides) -> runner.RunConfig:
    base = dict(
        url="http://router",
        max_tokens=16,
        temperature=None,
        concurrency=1,
        max_attempts=1,
        timeout_s=1.0,
        shuffle_seed=1,
    )
    base.update(overrides)
    return runner.RunConfig(**base)


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
        pool.write_text(
            "members:\n  - alias: m\neffort_levels:\n  m: [default, low, low, default]\n"
        )
        arms = catalog.arms(pool, [member("sclv/m", "m")])
        assert [a.effort for a in arms] == ["default", "low"]

    def test_a_declaration_for_a_member_that_is_gone_is_refused(self, tmp_path):
        """Silently shrinking a run wastes the whole run, so it is an error."""
        pool = tmp_path / "pool.yaml"
        pool.write_text(
            "members:\n  - alias: kept\neffort_levels:\n"
            "  kept: [default, high]\n  renamed-away: [default, high]\n"
        )
        with pytest.raises(catalog.ConfigError, match="renamed-away"):
            catalog.arms(pool, [member("sclv/kept", "kept")])

    def test_analysing_a_subset_of_the_pool_is_not_an_error(self, tmp_path):
        """The roster in the file is the reference, not the members passed in."""
        pool = tmp_path / "pool.yaml"
        pool.write_text(
            "members:\n  - alias: a\n  - alias: b\neffort_levels:\n  b: [default, high]\n"
        )
        arms = catalog.arms(pool, [member("sclv/a", "a")])
        assert [a.name for a in arms] == ["sclv/a"]


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

    def test_arms_of_one_member_are_addressed_to_that_member(self):
        arms = catalog.arms(POOL, [member("sclv/gpt-5.6-sol", "gpt-5.6-sol")])
        models = {t.model for t in runner.pinned_tasks([item("1")], arms)}
        assert models == {"sclv/gpt-5.6-sol"}

    def test_resume_skips_by_arm_and_question(self, tmp_path):
        out = tmp_path / "matrix.jsonl"
        out.write_text(
            json.dumps(
                {"arm": "pinned:m@low", "question_id": "1", "dataset": "MMLU-Pro"}
            )
            + "\n"
        )
        done = runner.completed_cells(out)
        tasks = [
            runner.Task(arm="pinned:m@low", model="m", item=item("1"), effort="low"),
            runner.Task(arm="pinned:m@high", model="m", item=item("1"), effort="high"),
        ]
        remaining = runner.plan(tasks, seed=1, skip=done)
        assert [t.arm for t in remaining] == ["pinned:m@high"]

    def test_a_failed_cell_counts_as_collected(self, tmp_path):
        """Retrying it on resume would give one arm more attempts than the others."""
        out = tmp_path / "matrix.jsonl"
        out.write_text(
            json.dumps(
                {
                    "arm": "pinned:m",
                    "question_id": "1",
                    "dataset": "MMLU-Pro",
                    "error": "http 502",
                }
            )
            + "\n"
        )
        assert runner.completed_cells(out) == {runner.cell_key("pinned:m", "1", "MMLU-Pro")}

    def test_the_same_question_id_in_another_dataset_is_another_cell(self, tmp_path):
        """Ids are not unique across corpora, and benchmarks are meant to plug in."""
        out = tmp_path / "matrix.jsonl"
        out.write_text(
            json.dumps(
                {"arm": "pinned:m", "question_id": "1", "dataset": "MMLU-Pro"}
            )
            + "\n"
        )
        other = dataset.Item(
            question_id="1",
            dataset="GPQA",
            category="math",
            fold="test",
            prompt="q",
            question={"answer": "A"},
        )
        tasks = [runner.Task(arm="pinned:m", model="m", item=other)]
        assert runner.plan(tasks, seed=1, skip=runner.completed_cells(out)) == tasks


class _Recorder:
    """A stand-in for the network that records what each call was asked to do."""

    def __init__(self, reject: set[str] | None = None, finish_reason: str = "stop"):
        self.reject = reject or set()
        self.finish_reason = finish_reason
        self.calls: list[dict] = []
        self.in_flight = 0
        self.peak_in_flight = 0

    async def call_once(self, session, url, **kwargs):
        self.calls.append(kwargs)
        self.in_flight += 1
        self.peak_in_flight = max(self.peak_in_flight, self.in_flight)
        # Suspends, so the other tasks reach the queue while this one is in flight.
        # Without it every fake call would complete before the next task started and
        # the concurrency assertions would pass on a scheduling accident.
        await asyncio.sleep(0)
        self.in_flight -= 1
        return self._response(kwargs["arm"])

    def _response(self, arm: str) -> client.Call:
        record = client.Call(
            arm=arm,
            requested_model="m",
            question_id="1",
            dataset="MMLU-Pro",
            category="math",
            fold="test",
        )
        if arm in self.reject:
            record.error = "http 400: unsupported value for reasoning_effort"
            record.arm_unsupported = True
        else:
            record.text = "Answer: A"
            record.finish_reason = self.finish_reason
        return record

    def arms_called(self, arm: str) -> int:
        return sum(1 for kwargs in self.calls if kwargs["arm"] == arm)


class _Graded:
    extracted, correct, parsed = "A", True, True


def drive(tmp_path, monkeypatch, tasks, recorder, **config_overrides):
    monkeypatch.setattr(runner.client, "call_once", recorder.call_once)
    monkeypatch.setattr(runner.score, "grade", lambda *a, **k: _Graded())
    stats = asyncio.run(
        runner.run(tasks, config(**config_overrides), tmp_path / "out.jsonl")
    )
    return stats


class TestWhatIsAskedFor:
    """The regression that would be invisible: every arm measured at one setting."""

    def test_each_arm_s_effort_reaches_the_request(self, tmp_path, monkeypatch):
        arms = catalog.arms(POOL, [member("sclv/gpt-5.6-sol", "gpt-5.6-sol")])
        recorder = _Recorder()
        drive(tmp_path, monkeypatch, runner.pinned_tasks([item("1")], arms), recorder)
        sent = {kwargs["arm"]: kwargs["reasoning_effort"] for kwargs in recorder.calls}
        assert sent == {
            "pinned:sclv/gpt-5.6-sol": None,
            "pinned:sclv/gpt-5.6-sol@none": "none",
            "pinned:sclv/gpt-5.6-sol@low": "low",
            "pinned:sclv/gpt-5.6-sol@high": "high",
        }

    def test_the_streaming_path_and_the_budget_reach_the_request(
        self, tmp_path, monkeypatch
    ):
        recorder = _Recorder()
        tasks = [runner.Task(arm="pinned:m", model="m", item=item("1"))]
        drive(
            tmp_path, monkeypatch, tasks, recorder, stream=True, max_tokens=4096,
            stream_idle_s=30.0,
        )
        assert recorder.calls[0]["stream"] is True
        assert recorder.calls[0]["max_tokens"] == 4096
        assert recorder.calls[0]["stream_idle_s"] == 30.0

    def test_no_stream_is_carried_through_rather_than_ignored(
        self, tmp_path, monkeypatch
    ):
        recorder = _Recorder()
        tasks = [runner.Task(arm="pinned:m", model="m", item=item("1"))]
        drive(tmp_path, monkeypatch, tasks, recorder, stream=False)
        assert recorder.calls[0]["stream"] is False

    def test_the_cli_streams_by_default_and_can_be_told_not_to(self):
        parser = collect.build_parser()
        assert parser.parse_args(["matrix"]).stream is True
        assert parser.parse_args(["matrix", "--no-stream"]).stream is False


class TestMemberGate:
    def test_arms_of_one_member_share_that_member_s_in_flight_limit(
        self, tmp_path, monkeypatch
    ):
        """The limit belongs to the serving member; four arms are still one server."""
        arms = catalog.arms(POOL, [member("sclv/gpt-5.6-sol", "gpt-5.6-sol", limit=1)])
        recorder = _Recorder()
        tasks = runner.pinned_tasks([item("1"), item("2")], arms)
        drive(
            tmp_path,
            monkeypatch,
            tasks,
            recorder,
            concurrency=8,
            per_model_concurrency=(("sclv/gpt-5.6-sol", 1),),
        )
        assert len(recorder.calls) == 8
        assert recorder.peak_in_flight == 1

    def test_without_a_declared_limit_the_run_wide_bound_applies(
        self, tmp_path, monkeypatch
    ):
        recorder = _Recorder()
        tasks = [
            runner.Task(arm="pinned:m", model="m", item=item(str(i))) for i in range(9)
        ]
        drive(tmp_path, monkeypatch, tasks, recorder, concurrency=3)
        assert recorder.peak_in_flight <= 3


class TestTruncationCounting:
    def test_the_rate_is_this_run_s_scored_calls(self, tmp_path, monkeypatch):
        recorder = _Recorder(finish_reason="length")
        tasks = [
            runner.Task(arm="pinned:m@high", model="m", item=item(str(i)))
            for i in range(4)
        ]
        stats = drive(tmp_path, monkeypatch, tasks, recorder)
        rates = stats.truncation_rates()
        assert rates["pinned:m@high"] == {"scored": 4, "truncated": 4, "rate": 1.0}

    def test_an_unfinished_arm_is_not_counted_as_truncated(self, tmp_path, monkeypatch):
        recorder = _Recorder(finish_reason="stop")
        tasks = [runner.Task(arm="pinned:m", model="m", item=item("1"))]
        stats = drive(tmp_path, monkeypatch, tasks, recorder)
        assert stats.truncation_rates()["pinned:m"]["rate"] == 0.0

    def test_the_threshold_is_policy_and_lives_outside_the_runner(self):
        """Counting is the runner's job; where the line falls is measurement policy."""
        assert 0 < quality.TRUNCATION_RATE < 1
        assert not hasattr(runner, "TRUNCATION_RATE_THRESHOLD")


class TestArmRetirement:
    """A rejected effort level means the arm is gone, not that a question failed."""

    def test_the_rest_of_a_rejected_arm_is_not_paid_for(self, tmp_path, monkeypatch):
        recorder = _Recorder(reject={"pinned:m@high"})
        tasks = [
            runner.Task(arm="pinned:m@high", model="m", item=item(str(i)), effort="high")
            for i in range(5)
        ]
        stats = drive(tmp_path, monkeypatch, tasks, recorder)
        assert len(recorder.calls) == 1
        assert stats.skipped == 4
        assert "pinned:m@high" in stats.retired_arms

    def test_only_the_calls_in_flight_are_wasted(self, tmp_path, monkeypatch):
        """The bound on waste is the concurrency, and it is not zero."""
        recorder = _Recorder(reject={"pinned:m@high"})
        tasks = [
            runner.Task(arm="pinned:m@high", model="m", item=item(str(i)), effort="high")
            for i in range(12)
        ]
        stats = drive(tmp_path, monkeypatch, tasks, recorder, concurrency=4)
        assert 1 <= len(recorder.calls) <= 4
        assert stats.skipped == 12 - len(recorder.calls)

    def test_retiring_one_arm_leaves_the_others_running(self, tmp_path, monkeypatch):
        recorder = _Recorder(reject={"pinned:m@high"})
        tasks = [
            runner.Task(arm=arm, model="m", item=item(str(i)))
            for i in range(3)
            for arm in ("pinned:m@high", "pinned:m")
        ]
        stats = drive(tmp_path, monkeypatch, tasks, recorder)
        assert recorder.arms_called("pinned:m") == 3
        assert recorder.arms_called("pinned:m@high") == 1
        assert list(stats.retired_arms) == ["pinned:m@high"]

    def test_the_rejection_itself_is_written_to_the_file(self, tmp_path, monkeypatch):
        """The row is the evidence the analysis needs to drop the arm."""
        recorder = _Recorder(reject={"pinned:m@high"})
        tasks = [
            runner.Task(arm="pinned:m@high", model="m", item=item(str(i)), effort="high")
            for i in range(3)
        ]
        drive(tmp_path, monkeypatch, tasks, recorder)
        rows = [
            json.loads(line)
            for line in (tmp_path / "out.jsonl").read_text().splitlines()
            if line.strip()
        ]
        assert len(rows) == 1
        assert rows[0]["arm_unsupported"] is True


class TestRetirementSurvivesTheProcess:
    """Retirement is a fact about the provider, not about one run."""

    def rejection_row(self, path: Path, arm: str) -> None:
        path.write_text(
            json.dumps(
                {
                    "arm": arm,
                    "question_id": "0",
                    "dataset": "MMLU-Pro",
                    "arm_unsupported": True,
                    "error": "http 400: unsupported reasoning_effort",
                    "stream": True,
                    "max_tokens": 16,
                    "temperature": None,
                }
            )
            + "\n"
        )

    def test_a_rejection_in_the_file_is_read_back(self, tmp_path):
        out = tmp_path / "m.jsonl"
        self.rejection_row(out, "pinned:m@high")
        assert "pinned:m@high" in runner.retired_arms(out)

    def test_a_resumed_run_does_not_buy_the_dead_arm_again(self, tmp_path, monkeypatch):
        out = tmp_path / "out.jsonl"
        self.rejection_row(out, "pinned:m@high")
        recorder = _Recorder(reject={"pinned:m@high"})
        monkeypatch.setattr(runner.client, "call_once", recorder.call_once)
        monkeypatch.setattr(runner.score, "grade", lambda *a, **k: _Graded())
        tasks = [
            runner.Task(arm="pinned:m@high", model="m", item=item(str(i)), effort="high")
            for i in range(1, 6)
        ]
        stats = asyncio.run(
            runner.run(
                tasks,
                config(stream=True, max_tokens=16),
                out,
                already_retired=runner.retired_arms(out),
            )
        )
        assert recorder.calls == []
        assert stats.skipped == 5

    def test_an_unproven_arm_sends_one_call_at_a_time(self, tmp_path, monkeypatch):
        """Until an arm answers once, a rejection would be bought once per slot."""
        recorder = _Recorder(reject={"pinned:m@high"})
        tasks = [
            runner.Task(arm="pinned:m@high", model="m", item=item(str(i)), effort="high")
            for i in range(12)
        ]
        stats = drive(tmp_path, monkeypatch, tasks, recorder, concurrency=8)
        assert len(recorder.calls) == 1
        assert stats.skipped == 11

    def test_a_proven_arm_is_not_serialised(self, tmp_path, monkeypatch):
        """The gate costs one call per arm, not the throughput of the run."""
        recorder = _Recorder()
        tasks = [
            runner.Task(arm="pinned:m", model="m", item=item(str(i))) for i in range(12)
        ]
        drive(tmp_path, monkeypatch, tasks, recorder, concurrency=4)
        assert len(recorder.calls) == 12
        assert recorder.peak_in_flight > 1


class TestSpendCeiling:
    """A completion cap is only free if the model does not expand to fill it."""

    def arms(self, price: float = 10.0):
        return [
            catalog.Arm(member=member("sclv/m", "m"), effort=effort)
            for effort in ("default", "high")
        ]

    def test_the_ceiling_is_per_arm_and_summed(self):
        worst = catalog.worst_case_usd(self.arms(), questions=100, max_tokens=1_000_000)
        # 2 USD per million completion tokens, 1 USD per million prompt tokens.
        assert worst["sclv/m"] == pytest.approx(100 * (2.0 + 400 / 1_000_000))
        assert worst["total"] == pytest.approx(2 * worst["sclv/m"])

    def test_raising_the_budget_raises_the_ceiling_proportionally(self):
        small = catalog.worst_case_usd(self.arms(), 10, 2048)["total"]
        large = catalog.worst_case_usd(self.arms(), 10, 16384)["total"]
        assert large > small * 7

    def test_a_run_over_the_limit_stops_before_calling(self, capsys):
        with pytest.raises(SystemExit, match="exceeds --max-spend-usd"):
            collect.guard_spend(self.arms(), questions=1000, max_tokens=16384, limit=1.0)

    def test_without_a_limit_the_ceiling_is_still_printed(self, capsys):
        collect.guard_spend(self.arms(), questions=10, max_tokens=2048, limit=None)
        assert "ceiling" in capsys.readouterr().out


class TestEffortRejectionPredicate:
    """What retires an arm. Too narrow pays a 400 per question; too wide kills a live arm."""

    @pytest.mark.parametrize(
        "body",
        [
            '{"error": {"param": "reasoning_effort", "message": "unsupported"}}',
            '{"error": {"message": "reasoning_effort: none is not supported"}}',
            "unsupported value for reasoning.effort",
            "this model does not accept a reasoning effort",
        ],
    )
    def test_a_rejected_level_is_recognised(self, body):
        assert client.rejected_the_effort_level(body, 400) is True

    @pytest.mark.parametrize(
        "body",
        [
            '{"error": {"param": "temperature", "message": "must be 1"}}',
            '{"error": {"message": "context length exceeded"}}',
            "max_tokens must be a positive integer",
        ],
    )
    def test_another_validation_error_does_not_retire_the_arm(self, body):
        assert client.rejected_the_effort_level(body, 400) is False

    def test_a_named_parameter_beats_the_prose(self):
        """A body that lists every accepted field must not retire a working arm."""
        body = json.dumps(
            {
                "error": {
                    "param": "temperature",
                    "message": "accepted: temperature, reasoning_effort, max_tokens",
                }
            }
        )
        assert client.rejected_the_effort_level(body, 400) is False

    def test_mentioning_the_field_is_not_enough_without_a_refusal(self):
        """The same trap with no `param` to go on: an enumeration is not a rejection."""
        body = json.dumps(
            {"error": {"message": "accepted fields: temperature, reasoning_effort"}}
        )
        assert client.rejected_the_effort_level(body, 400) is False

    def test_only_a_400_can_retire_an_arm(self):
        body = '{"error": {"param": "reasoning_effort"}}'
        assert client.rejected_the_effort_level(body, 500) is False


class _Stream:
    """A response whose SSE lines arrive on a schedule, for testing the watchdog."""

    def __init__(self, lines: list[tuple[float, bytes]]):
        self._lines = list(lines)
        self.content = self

    async def readline(self) -> bytes:
        if not self._lines:
            return b""
        delay, line = self._lines.pop(0)
        await asyncio.sleep(delay)
        return line


def sse(**event) -> bytes:
    return b"data: " + json.dumps(event).encode() + b"\n"


def chunk(text: str) -> bytes:
    return sse(choices=[{"delta": {"content": text}}])


def consume(response, **kwargs) -> client.Call:
    record = client.Call(
        arm="pinned:m",
        requested_model="m",
        question_id="1",
        dataset="MMLU-Pro",
        category="math",
        fold="test",
    )
    asyncio.run(
        client._consume_stream(record, response, 0.0, **kwargs)
    )
    return record


class TestStreamWatchdog:
    """What the deadline is measured on decides which arms survive."""

    def test_a_keep_alive_is_not_progress(self):
        """A byte-level deadline would call a hung upstream healthy."""
        response = _Stream([(0.0, b": ping\n")] * 5 + [(0.0, chunk("A"))])
        with pytest.raises(asyncio.TimeoutError):
            consume(response, idle_s=0.0, first_event_s=0.0)

    def test_a_slow_first_event_is_allowed(self):
        """A provider that buffers its thinking says nothing while doing the work."""
        response = _Stream([(0.05, chunk("Answer: A"))])
        record = consume(response, idle_s=0.01, first_event_s=5.0)
        assert record.text == "Answer: A"

    def test_a_stream_that_stops_mid_answer_is_cut(self):
        response = _Stream([(0.0, chunk("Ans")), (0.5, chunk("wer"))])
        with pytest.raises(asyncio.TimeoutError):
            consume(response, idle_s=0.05, first_event_s=5.0)

    def test_what_arrived_before_the_break_is_kept(self):
        """Those tokens were generated and billed; the fragment is the only record."""
        record = client.Call(
            arm="pinned:m",
            requested_model="m",
            question_id="1",
            dataset="MMLU-Pro",
            category="math",
            fold="test",
        )
        response = _Stream([(0.0, chunk("partial")), (0.5, chunk("never arrives"))])
        with pytest.raises(asyncio.TimeoutError):
            asyncio.run(
                client._consume_stream(
                    record, response, 0.0, idle_s=0.05, first_event_s=5.0
                )
            )
        assert record.text == "partial"
        assert record.content_chunks == 1

    def test_usage_and_finish_reason_are_read(self):
        response = _Stream(
            [
                (0.0, chunk("Answer: A")),
                (
                    0.0,
                    sse(
                        choices=[{"finish_reason": "length"}],
                        usage={
                            "prompt_tokens": 10,
                            "completion_tokens": 20,
                            "completion_tokens_details": {"reasoning_tokens": 15},
                        },
                    ),
                ),
                (0.0, b"data: [DONE]\n"),
            ]
        )
        record = consume(response, idle_s=1.0, first_event_s=1.0)
        assert record.finish_reason == "length"
        assert record.completion_tokens == 20
        assert record.reasoning_tokens == 15


class TestSettingsGuard:
    """A file holds one setting, because the arm name cannot carry them all."""

    def rows(self, path: Path, *, labelled: bool = True, **fields):
        """One recorded row. `labelled` writes every field the guard checks, since a
        row missing any of them is unknown rather than matching or mismatching."""
        row = {"arm": "pinned:m", "question_id": "1", "dataset": "MMLU-Pro"}
        if labelled:
            row.update({"stream": True, "max_tokens": 16, "temperature": None})
        row.update(fields)
        path.write_text(json.dumps(row) + "\n")

    def test_a_new_file_is_fine(self, tmp_path):
        assert runner.settings_conflict(tmp_path / "new.jsonl", config()) is None

    def test_matching_settings_are_fine(self, tmp_path):
        out = tmp_path / "m.jsonl"
        self.rows(out, stream=True, max_tokens=16)
        assert runner.settings_conflict(out, config(stream=True, max_tokens=16)) is None

    def test_a_different_budget_is_refused(self, tmp_path):
        out = tmp_path / "m.jsonl"
        self.rows(out, stream=True, max_tokens=2048)
        conflict = runner.settings_conflict(out, config(max_tokens=16384, stream=True))
        assert conflict and "max_tokens" in conflict

    def test_a_different_path_is_refused(self, tmp_path):
        out = tmp_path / "m.jsonl"
        self.rows(out, stream=False, max_tokens=16)
        conflict = runner.settings_conflict(out, config(stream=True, max_tokens=16))
        assert conflict and "stream" in conflict

    def test_rows_from_before_the_fields_existed_are_refused_as_unknown(self, tmp_path):
        """v1's rows record neither, and are exactly the ones that would be mixed in."""
        out = tmp_path / "v1.jsonl"
        self.rows(out, labelled=False)
        conflict = runner.settings_conflict(out, config())
        assert conflict and "before the request settings were recorded" in conflict

    def test_a_row_missing_one_field_is_unknown_and_not_a_mismatch(self, tmp_path):
        """Reporting it as a mismatch would name the wrong reason for refusing."""
        out = tmp_path / "half.jsonl"
        self.rows(out, labelled=False, stream=True)  # no max_tokens, no temperature
        conflict = runner.settings_conflict(out, config(stream=True, max_tokens=16))
        assert conflict and "before the request settings were recorded" in conflict

    def test_a_different_temperature_is_refused(self, tmp_path):
        out = tmp_path / "m.jsonl"
        self.rows(out, stream=True, max_tokens=16, temperature=0.0)
        conflict = runner.settings_conflict(out, config(temperature=None))
        assert conflict and "temperature" in conflict

    def test_a_different_censoring_point_warns_but_does_not_refuse(self, tmp_path):
        """A completed call still means the same thing; which calls complete does not."""
        out = tmp_path / "m.jsonl"
        self.rows(out, stream=True, max_tokens=16, temperature=None, stream_idle_s=30.0)
        cfg = config(stream=True, max_tokens=16, stream_idle_s=90.0)
        assert runner.settings_conflict(out, cfg) is None
        drift = runner.censoring_drift(out, cfg)
        assert drift and "stream_idle_s" in drift

    def test_the_cli_refuses_rather_than_appends(self, tmp_path):
        out = tmp_path / "m.jsonl"
        self.rows(out, stream=False, max_tokens=16)
        with pytest.raises(SystemExit):
            collect.guard_output(out, config(stream=True, max_tokens=16))


class TestExitCode:
    def test_a_run_with_nothing_left_to_do_has_not_failed(self, capsys):
        assert collect.report_run(runner.RunStats(), Path("unused")) == 0

    def test_a_run_where_every_call_failed_has_failed(self, capsys):
        assert collect.report_run(runner.RunStats(failed=3), Path("unused")) == 1

    def test_an_arm_that_failed_alone_is_reported(self, capsys):
        """A failed cell counts as collected, so an asymmetric outage is permanent."""
        stats = runner.RunStats(
            ok=18,
            failed=9,
            scored_by_arm={"pinned:m": 9, "pinned:m@low": 9, "pinned:m@high": 0},
            failed_by_arm={"pinned:m@high": 9},
        )
        assert collect.report_run(stats, Path("unused")) == 0
        printed = capsys.readouterr().out
        assert "did not fail alike" in printed and "pinned:m@high" in printed

    def test_arms_failing_alike_is_not_flagged_as_asymmetry(self, capsys):
        stats = runner.RunStats(
            ok=18,
            failed=2,
            scored_by_arm={"pinned:m": 9, "pinned:m@low": 9},
            failed_by_arm={"pinned:m": 1, "pinned:m@low": 1},
        )
        collect.report_run(stats, Path("unused"))
        assert "did not fail alike" not in capsys.readouterr().out

    def test_warnings_do_not_change_the_code(self, capsys):
        """The Job retries on a non-zero exit, and a retry would re-spend the money."""
        stats = runner.RunStats(
            ok=10,
            retired_arms={"pinned:m@high": "http 400"},
            scored_by_arm={"pinned:m": 10},
            truncated_by_arm={"pinned:m": 10},
        )
        assert collect.report_run(stats, Path("unused")) == 0
        printed = capsys.readouterr().out
        assert "retired" in printed and "completion budget" in printed


class TestPowerScreen:
    """The screen decides whether v2 runs at all, so its arithmetic is fixed here."""

    def test_a_disagreement_rate_is_twice_the_variance_of_one_ask(self):
        """Two asks disagree with probability 2p(1-p); one ask has variance p(1-p)."""
        assert power.per_ask_variance(0.2) == pytest.approx(0.1)

    def test_required_n_scales_with_discordance_and_inversely_with_the_square(self):
        assert power.n_for(0.1, 0.02) == pytest.approx(power.n_for(0.05, 0.02) * 2, rel=0.01)
        assert power.n_for(0.1, 0.01) == pytest.approx(power.n_for(0.1, 0.02) * 4, rel=0.01)

    def test_the_detectable_difference_at_a_given_n(self):
        # 2.8016 * sqrt(0.1/693) = 0.03366
        assert power.mde_at(0.1, 693) == pytest.approx(0.0337, abs=1e-4)

    def test_the_variance_split_floors_at_zero(self):
        """A noise term larger than the spread means the two are not separable here."""
        differences = np.array([0.1, -0.1, 0.0, 0.05])
        truth, measurement = power.variance_split(differences, flip_a=0.9, flip_b=0.9)
        assert truth == 0.0 and measurement == pytest.approx(0.9)

    def test_more_asks_per_cell_narrows_the_spread(self):
        differences = np.array([1.0, -1.0, 0.0, 1.0, -1.0] * 20)
        one = power.at_samples_per_cell(differences, flip_a=0.1, flip_b=0.1, samples=1)
        three = power.at_samples_per_cell(differences, flip_a=0.1, flip_b=0.1, samples=3)
        assert one.var(ddof=1) > three.var(ddof=1)
        assert one.mean() == pytest.approx(three.mean())

    def test_one_ask_is_the_data_as_measured(self):
        """The observed rows already contain one draw of the noise."""
        differences = np.array([1.0, -1.0, 0.0])
        same = power.at_samples_per_cell(differences, flip_a=0.1, flip_b=0.2, samples=1)
        assert np.allclose(same, differences)

    def test_the_test_holds_its_size_under_the_null(self):
        rng = np.random.default_rng(3)
        differences = rng.normal(0.0, 0.25, 693)
        rejected = power.bootstrap_power(
            differences, delta=0.0, n=693, sims=4000, rng=rng
        )
        assert 0.03 < rejected < 0.08

    def test_power_rises_with_n(self):
        rng = np.random.default_rng(5)
        differences = rng.normal(0.0, 0.25, 693)
        small = power.bootstrap_power(differences, delta=0.02, n=693, sims=2000, rng=rng)
        large = power.bootstrap_power(differences, delta=0.02, n=4000, sims=2000, rng=rng)
        assert large > small

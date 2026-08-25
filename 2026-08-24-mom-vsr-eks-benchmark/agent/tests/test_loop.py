"""Tests for the parts of the loop that decide who takes a step and what it cost.

None of this needs a network or a container, which is deliberate: the routing decision,
the escalation latch and the cost arithmetic are exactly the places where a mistake
produces a plausible number rather than a crash. The transport and the tools that touch
`/testbed` are exercised on a real instance instead, because mocking a filesystem would
test the mock.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

AGENT = Path(__file__).resolve().parents[1]
if str(AGENT) not in sys.path:
    sys.path.insert(0, str(AGENT))

import loop  # noqa: E402
import policy as pol  # noqa: E402
import tools  # noqa: E402
import transport  # noqa: E402


def _bare_step(index: int, *, usd: float = 0.1, estimated: bool = False) -> loop.Step:
    """The fields a diagnosis reads, and defaults for the rest."""
    return loop.Step(
        index=index, tier=pol.CHEAP, route_reason="", model="m", step_type="read",
        tool="read_file", signature="read_file:a", ok=True, tests_passed=None,
        finish_reason="stop", latency_ms=1.0, ttft_ms=1.0, prompt_tokens=10,
        fresh_prompt_tokens=10, cached_prompt_tokens=0, cache_write_tokens=0,
        completion_tokens=5, reasoning_tokens=0, usd=usd, usd_estimated=estimated,
    )


def budget(**kwargs) -> pol.Budget:
    base = {"max_steps": 40, "max_tokens": 400_000, "repeat_k": 3, "max_usd": 5.0}
    return pol.Budget(**{**base, **kwargs})


class TestActionParsing:
    def test_the_committed_action_wins_over_an_illustrated_one(self):
        """A model that shows the syntax before using it must not have the example run."""
        text = (
            'For example I could write <action tool="read_file">\npath: a.py\n</action>\n'
            'but what I actually want is <action tool="search">\npattern: retry\n</action>'
        )
        action = tools.parse(text)
        assert action.tool == "search" and action.args["pattern"] == "retry"

    def test_a_patch_body_containing_a_key_is_not_reparsed(self):
        text = (
            '<action tool="write_patch">\n'
            "path: requests/models.py\n"
            "old: <<<\n    path: str = ''\n>>>\n"
            "new: <<<\n    path: str = '/'\n>>>\n"
            "</action>"
        )
        action = tools.parse(text)
        assert action.args["path"] == "requests/models.py"
        assert action.args["old"] == "    path: str = ''"
        assert action.args["new"] == "    path: str = '/'"

    def test_prose_with_no_action_is_not_an_action(self):
        assert tools.parse("I think the bug is in models.py.") is None

    def test_all_actions_are_available_for_a_multi_file_patch(self):
        text = (
            '<action tool="write_patch">\npath: a.py\nold: <<<\nx\n>>>\nnew: <<<\ny\n>>>\n</action>\n'
            '<action tool="write_patch">\npath: b.py\nold: <<<\nz\n>>>\nnew: <<<\nw\n>>>\n</action>'
        )
        assert [a.args["path"] for a in tools.parse_all(text)] == ["a.py", "b.py"]


class TestTurnsWithSeveralActions:
    """The first real run lost a premium model's patch because only the last action ran."""

    def test_a_patch_and_a_done_in_one_turn_are_both_kept(self):
        text = (
            '<action tool="write_patch">\npath: a.py\nold: <<<\nx\n>>>\nnew: <<<\ny\n>>>\n</action>\n'
            '<action tool="done">\nnote: fixed\n</action>'
        )
        actions = tools.parse_all(text)
        assert [a.tool for a in actions] == ["write_patch", "done"]

    def test_the_turn_is_recorded_as_its_most_consequential_action(self):
        """Calling it a finish step would move the patch cost out of the patch share."""
        actions = [
            tools.Action(tool="done", args={}),
            tools.Action(tool="write_patch", args={"path": "a.py"}),
        ]
        assert tools.principal(actions).tool == "write_patch"

    def test_a_read_then_a_patch_is_a_patch_step(self):
        actions = [
            tools.Action(tool="read_file", args={"path": "a.py"}),
            tools.Action(tool="write_patch", args={"path": "a.py"}),
        ]
        assert tools.principal(actions).step_type == "patch"

    def test_a_turn_of_only_searches_is_a_search_step(self):
        actions = [tools.Action(tool="search", args={"pattern": "x"})]
        assert tools.principal(actions).step_type == "search"

    def test_no_actions_has_no_principal(self):
        assert tools.principal([]) is None


class TestArgumentQuoting:
    def test_a_quoted_path_is_unquoted(self):
        """Models write it both ways, and a path with quotes in it does not exist."""
        action = tools.parse('<action tool="read_file">\npath: "requests/models.py"\n</action>')
        assert action.args["path"] == "requests/models.py"

    def test_a_single_quoted_path_too(self):
        action = tools.parse("<action tool=\"read_file\">\npath: 'a/b.py'\n</action>")
        assert action.args["path"] == "a/b.py"

    def test_an_apostrophe_inside_a_value_is_left_alone(self):
        action = tools.parse('<action tool="search">\npattern: don\'t\n</action>')
        assert action.args["pattern"] == "don\'t"


class TestProtocolText:
    def test_a_withheld_tool_is_not_advertised(self):
        """Offering a tool and then refusing it charges the arm a turn for nothing."""
        text = tools.protocol(withhold=("write_patch",), add=("handoff",))
        assert "write_patch" not in text
        assert "handoff" in text

    def test_the_multi_line_entry_leaves_nothing_behind(self):
        """Its continuation lines are part of the entry, not stray lines to filter."""
        text = tools.protocol(withhold=("write_patch",))
        assert "old: <<<" not in text and "new: <<<" not in text

    def test_a_rule_about_a_withheld_tool_goes_with_it(self):
        assert "appear exactly once" in tools.protocol()
        assert "appear exactly once" not in tools.protocol(withhold=("write_patch",))

    def test_the_example_uses_a_tool_that_is_on_offer(self):
        """A generic skeleton lost the hint that paths are relative, and the next cheap
        model sent an absolute one with the repository name twice."""
        assert "path: requests/models.py" in tools.protocol()
        patch_only = tools.protocol(
            withhold=("list_dir", "search", "read_file", "run_tests", "done"),
            one_per_turn=False,
        )
        assert 'tool="write_patch"' in patch_only
        assert 'tool="read_file"' not in patch_only

    def test_a_tool_that_does_not_exist_is_an_error(self):
        with pytest.raises(ValueError):
            tools.protocol(withhold=("compile",))


class TestStepLabels:
    """The label comes from the tool, so a model cannot relabel its own work."""

    @pytest.mark.parametrize(
        "tool,expected",
        [
            ("search", "search"),
            ("list_dir", "search"),
            ("read_file", "read"),
            ("run_tests", "verify"),
            ("write_patch", "patch"),
        ],
    )
    def test_the_tool_decides_the_step_type(self, tool, expected):
        assert tools.Action(tool=tool, args={}).step_type == expected

    def test_a_window_move_is_not_the_same_action(self):
        """Reading the next page is progress; reading the same page again is a loop."""
        first = tools.Action(tool="read_file", args={"path": "a.py", "start": "1"})
        second = tools.Action(tool="read_file", args={"path": "a.py", "start": "400"})
        assert first.signature == second.signature  # same target...
        third = tools.Action(tool="read_file", args={"path": "b.py"})
        assert third.signature != first.signature

    def test_a_test_path_is_recognised_wherever_it_lives(self):
        assert tools.is_test_path("tests/test_models.py")
        assert tools.is_test_path("test_requests.py")
        assert not tools.is_test_path("requests/models.py")
        assert not tools.is_test_path("src/latest.py")


class TestTriggers:
    def test_a_failing_test_after_an_edit_fires(self):
        state = pol.EpisodeState(last_tests_passed=False, has_patched=True)
        assert "verifier_disagreed" in pol.fired_triggers(state, budget())

    def test_a_failing_test_before_any_edit_does_not(self):
        """Reproducing the reported bug is the first thing a competent agent does. Firing
        there escalates every episode on its first test run and measures nothing."""
        state = pol.EpisodeState(last_tests_passed=False, has_patched=False)
        assert "verifier_disagreed" not in pol.fired_triggers(state, budget())

    def test_a_passing_test_does_not(self):
        state = pol.EpisodeState(last_tests_passed=True, has_patched=True)
        assert pol.fired_triggers(state, budget()) == ()

    def test_a_step_that_said_nothing_about_correctness_does_not_fire(self):
        """None is not False: a search says nothing about whether the code is right."""
        assert pol.fired_triggers(pol.EpisodeState(last_tests_passed=None), budget()) == ()

    def test_the_same_action_three_times_fires(self):
        state = pol.EpisodeState(signatures=["read_file(path=a.py)"] * 3)
        assert any("same_action" in r for r in pol.fired_triggers(state, budget()))

    def test_the_same_action_twice_does_not(self):
        state = pol.EpisodeState(signatures=["read_file(path=a.py)"] * 2)
        assert not any("same_action" in r for r in pol.fired_triggers(state, budget()))

    def test_three_different_edits_to_one_file_are_not_a_loop(self):
        """They share a path. Without the edit in the signature the detector escalates a
        working agent for making progress."""
        edits = [
            tools.Action(tool="write_patch", args={"path": "a.py", "old": text})
            for text in ("first block", "second block", "third block")
        ]
        state = pol.EpisodeState(signatures=[e.signature for e in edits])
        assert not any("same_action" in r for r in pol.fired_triggers(state, budget()))

    def test_the_same_edit_three_times_still_is(self):
        same = tools.Action(tool="write_patch", args={"path": "a.py", "old": "one block"})
        state = pol.EpisodeState(signatures=[same.signature] * 3)
        assert any("same_action" in r for r in pol.fired_triggers(state, budget()))

    def test_a_repeat_that_was_interrupted_is_not_a_loop(self):
        state = pol.EpisodeState(
            signatures=["read_file(path=a.py)", "search(pattern=x)", "read_file(path=a.py)"]
        )
        assert not any("same_action" in r for r in pol.fired_triggers(state, budget()))

    def test_the_budget_backstop_fires_before_the_budget_is_gone(self):
        """Escalating at the last step would leave nothing for the premium model to do."""
        state = pol.EpisodeState(steps=30)
        assert "step_budget_75%" in pol.fired_triggers(state, budget(max_steps=40))


class TestBrokenStreams:
    """Usage arrives in the terminal chunk, so a stream that breaks reports nothing."""

    def test_an_unpriced_call_is_recognised(self):
        assert not transport.Reply(model="x").priced
        assert transport.Reply(model="x", completion_tokens=5).priced

    def test_it_is_approximated_rather_than_left_free(self):
        """A free step would also slip past the spend ceiling, and long streams break most."""
        reply = transport.Reply(model="x", text="a" * 400)
        reply.estimate_usage(request_chars=8_000)
        assert reply.prompt_tokens == 2_000 and reply.completion_tokens == 100
        assert reply.estimated

    def test_an_estimate_keeps_the_tiers_own_cache_share(self):
        """Pricing the whole prompt as fresh is ten times the cache price and falls hardest
        on the long premium thread, which is the baseline."""
        reply = transport.Reply(model="x", text="")
        reply.estimate_usage(request_chars=40_000, cached_share=0.9)
        assert reply.prompt_tokens == 10_000
        assert reply.cached_prompt_tokens == 9_000
        assert reply.fresh_prompt_tokens == 1_000

    def test_without_a_known_share_it_is_all_fresh_and_flagged(self):
        reply = transport.Reply(model="x", text="")
        reply.estimate_usage(request_chars=4_000)
        assert reply.cached_prompt_tokens == 0 and reply.estimated

    def test_a_priced_call_is_left_alone(self):
        reply = transport.Reply(model="x", prompt_tokens=123, completion_tokens=4)
        reply.estimate_usage(request_chars=99_999)
        assert reply.prompt_tokens == 123 and not reply.estimated


class TestPytestStatuses:
    def test_a_usage_error_says_nothing_about_the_code(self):
        """Reporting a mistyped target as a failure escalates the episode for nothing."""
        assert tools._verdict(4) is None
        assert tools._verdict(5) is None

    def test_a_real_failure_still_reads_as_one(self):
        assert tools._verdict(1) is False
        assert tools._verdict(0) is True


class TestExhaustion:
    def test_running_out_of_money_stops_the_episode(self):
        state = pol.EpisodeState(spend_usd=5.0)
        assert pol.exhausted(state, budget(max_usd=5.0)) == "spend ceiling reached"

    def test_an_episode_with_room_left_continues(self):
        assert pol.exhausted(pol.EpisodeState(steps=1), budget()) is None


class TestOneWayEscalation:
    def test_it_starts_cheap(self):
        assert pol.OneWayEscalation().decide(pol.EpisodeState()).tier == pol.CHEAP

    def test_a_trigger_moves_it_to_premium(self):
        strategy, state = pol.OneWayEscalation(), pol.EpisodeState(
            last_tests_passed=False, has_patched=True
        )
        assert strategy.consider(state, budget()) != ()
        assert strategy.decide(state).tier == pol.PREMIUM

    def test_it_never_comes_back(self):
        """Round trips pay the accumulated context each way; eight of them cost more than
        never having left the premium model."""
        strategy, state = pol.OneWayEscalation(), pol.EpisodeState(
            last_tests_passed=False, has_patched=True
        )
        strategy.consider(state, budget())
        escalated_at = state.escalated_at
        state.last_tests_passed = True  # the premium model fixed it
        assert strategy.decide(state).tier == pol.PREMIUM
        assert state.escalated_at == escalated_at

    def test_the_latch_records_one_event_not_one_per_step(self):
        strategy, state = pol.OneWayEscalation(), pol.EpisodeState(
            last_tests_passed=False, has_patched=True
        )
        for _ in range(5):
            strategy.consider(state, budget())
        assert len(state.triggers_fired) == 1

    def test_the_reason_is_recorded_with_the_step(self):
        strategy = pol.OneWayEscalation()
        state = pol.EpisodeState(steps=7, last_tests_passed=False, has_patched=True)
        strategy.consider(state, budget())
        assert state.triggers_fired == [{"step": 7, "reasons": ["verifier_disagreed"]}]


class TestFixedPolicies:
    def test_premium_never_leaves_the_premium_tier(self):
        state = pol.EpisodeState(last_tests_passed=False, has_patched=True, steps=39)
        assert pol.PremiumOnly().decide(state).tier == pol.PREMIUM
        assert pol.PremiumOnly().consider(state, budget()) == ()

    def test_cheap_never_escalates_even_when_a_trigger_holds(self):
        state = pol.EpisodeState(last_tests_passed=False, has_patched=True)
        assert pol.CheapOnly().decide(state).tier == pol.CHEAP
        assert not state.escalated

    def test_every_policy_declares_the_tiers_it_can_ask_for(self):
        """Inferring this in the driver meant a new policy silently got the wrong answer."""
        assert pol.PremiumOnly().required_tiers == (pol.PREMIUM,)
        assert set(pol.OneWayEscalation().required_tiers) == {pol.CHEAP, pol.PREMIUM}
        assert set(pol.CapacityFirst(inflight=lambda: 0).required_tiers) == {
            pol.SELF_HOSTED, pol.CHEAP
        }

    def test_a_policy_that_does_not_hand_off_refuses_to_name_a_patch_tier(self):
        with pytest.raises(NotImplementedError):
            pol.CheapOnly().patch_tier()


class TestCapacityFirst:
    def test_it_uses_the_paid_for_machine_when_there_is_room(self):
        strategy = pol.CapacityFirst(inflight=lambda: 4, ceiling=48, safety=0.7)
        assert strategy.decide(pol.EpisodeState()).tier == pol.SELF_HOSTED

    def test_it_spills_at_the_safety_factor_not_at_the_ceiling(self):
        strategy = pol.CapacityFirst(inflight=lambda: 34, ceiling=48, safety=0.7)
        assert strategy.admit_below == pytest.approx(33.6)
        assert strategy.decide(pol.EpisodeState()).tier == pol.CHEAP

    def test_an_unreadable_count_spills(self):
        """Sending into a queue of unknown depth records the queue as the model's latency."""
        assert pol.CapacityFirst(inflight=lambda: None).decide(pol.EpisodeState()).tier == (
            pol.CHEAP
        )

    def test_a_broken_metrics_endpoint_spills_rather_than_raising(self):
        def explode():
            raise OSError("connection refused")

        assert pol.CapacityFirst(inflight=explode).decide(pol.EpisodeState()).tier == pol.CHEAP

    def test_a_full_machine_and_a_broken_probe_are_told_apart(self):
        """Both spill. Reported identically, a policy that never ran is a cheap-always run."""
        def explode():
            raise OSError("connection refused")

        full = pol.CapacityFirst(inflight=lambda: 99).decide(pol.EpisodeState()).reason
        broken = pol.CapacityFirst(inflight=explode).decide(pol.EpisodeState()).reason
        assert full != broken
        assert "in flight" in full and "unreadable" in broken

    def test_withdrawing_the_arm_is_recorded(self):
        """Dropping an arm's worst steps flatters it, so it cannot happen silently."""
        strategy = pol.CapacityFirst(inflight=lambda: 0, malformed_limit=3)
        state = pol.EpisodeState(steps=12)
        for _ in range(3):
            state.note_malformed(pol.SELF_HOSTED)
        decision = strategy.decide(state)
        assert decision.tier == pol.CHEAP and "step 12" in decision.reason

    def test_it_stays_withdrawn(self):
        strategy = pol.CapacityFirst(inflight=lambda: 0, malformed_limit=3)
        state = pol.EpisodeState()
        for _ in range(3):
            state.note_malformed(pol.SELF_HOSTED)
        strategy.decide(state)
        assert strategy.decide(pol.EpisodeState()).tier == pol.CHEAP

    def test_the_cheap_tiers_mistakes_do_not_retire_the_machine(self):
        """A shared counter let the cheap model's format errors withdraw the GPU, and the
        log then blamed the GPU."""
        strategy = pol.CapacityFirst(inflight=lambda: 0, malformed_limit=3)
        state = pol.EpisodeState()
        for _ in range(5):
            state.note_malformed(pol.CHEAP)
        assert strategy.decide(state).tier == pol.SELF_HOSTED
        assert strategy.withdrawn is None

    def test_the_shared_state_carries_no_policy_specific_field(self):
        """A state object that grows a field per policy hands the next policy five it
        does not use."""
        assert not hasattr(pol.EpisodeState(), "self_hosted_withdrawn")


class TestRoleBased:
    def test_the_worker_cannot_write_the_patch(self):
        assert "write_patch" in pol.RoleBased().withholds

    def test_the_decisive_step_goes_to_premium(self):
        assert pol.RoleBased().patch_tier() == pol.PREMIUM

    def test_the_worker_tier_is_the_one_asked_for(self):
        assert pol.RoleBased(worker_tier=pol.SELF_HOSTED).decide(
            pol.EpisodeState()
        ).tier == pol.SELF_HOSTED

    def test_it_does_not_escalate_the_thread(self):
        """Its premium call is a fresh request, so there is no handover to latch."""
        state = pol.EpisodeState(last_tests_passed=False, has_patched=True)
        assert pol.RoleBased().consider(state, budget()) == ()
        assert not state.escalated

    def test_the_table_is_fixed_in_code(self):
        assert pol.ROLE_TABLE["patch"] == pol.DECIDER
        assert pol.ROLE_TABLE["search"] == pol.WORKER

    def test_the_table_is_what_decides_which_tools_are_withheld(self):
        """Otherwise the table is decoration and the withholding is a hardcoded list."""
        assert pol.decider_tools() == ("write_patch",)

    def test_a_change_to_the_table_changes_what_is_withheld(self, monkeypatch):
        monkeypatch.setitem(pol.ROLE_TABLE, "verify", pol.DECIDER)
        assert set(pol.decider_tools()) == {"write_patch", "run_tests"}

    def test_a_self_hosted_worker_still_has_tools(self):
        """A table written in tiers withheld everything from it and left it nothing to do."""
        strategy = pol.RoleBased(worker_tier=pol.SELF_HOSTED)
        assert strategy.withholds == ("write_patch",)
        assert set(strategy.required_tiers) == {pol.SELF_HOSTED, pol.PREMIUM}

    def test_the_handoff_turn_is_not_counted_as_a_patch(self):
        """Folding the cheap turn into the patch share inflates what routing can save."""
        assert tools.STEP_TYPE["handoff"] == "handoff"
        assert tools.STEP_TYPE["write_patch"] == "patch"


class TestSwitchTax:
    def rate(self) -> pol.Rate:
        return pol.Rate(key="fable", fresh_in=10.0, out=50.0, cache_read=1.0, cache_write=12.5)

    def test_it_charges_the_difference_between_what_was_paid_and_the_cache_price(self):
        # 100k fresh at $10 rather than $1, and 50k stored at $12.50 rather than $1.
        assert pol.switch_tax_usd(
            self.rate(), fresh_in=100_000, cache_write=50_000
        ) == pytest.approx(0.9 + 0.575)

    def test_a_turn_served_entirely_from_cache_pays_no_tax(self):
        """Which is what a warm model looks like, and is the point of comparison."""
        assert pol.switch_tax_usd(self.rate(), fresh_in=0, cache_write=0) == 0.0


class TestBudget:
    def test_the_dollar_ceiling_is_far_above_the_step_budget(self):
        """A ceiling that binds binds the premium baseline first, which would hand the
        non-inferiority claim a free win."""
        assert pol.Budget().max_usd >= 20.0

    def test_the_escalation_fraction_is_named_not_buried(self):
        state = pol.EpisodeState(steps=5)
        assert any("50%" in r for r in pol.fired_triggers(state, budget(max_steps=10,)) ) is False
        loose = pol.Budget(max_steps=10, escalate_at=0.5)
        assert any("50%" in r for r in pol.fired_triggers(state, loose))


class TestRoster:
    def test_asking_for_a_tier_the_run_does_not_have_is_an_error(self):
        """A silent fallback would report one model's cost under another's name."""
        roster = pol.Roster(
            premium=pol.Model(pol.PREMIUM, "fable", "fable"),
            cheap=pol.Model(pol.CHEAP, "terra", "gpt-5.6-terra"),
        )
        with pytest.raises(KeyError):
            roster.of(pol.SELF_HOSTED)


class TestUnreachableIsStillBilled:
    def test_the_failed_attempts_travel_with_the_exception(self):
        """An episode that died on its last retry lost every attempt from the totals, and
        the tier with the strictest rate limits is the premium one."""
        exc = transport.Unreachable("http 429", [{"fresh_in": 100, "cache_read": 0,
                                                 "cache_write": 0, "out": 0}])
        assert exc.billed and exc.billed[0]["fresh_in"] == 100

    def test_an_exception_without_billing_is_still_valid(self):
        assert transport.Unreachable("gone").billed == []


class TestCost:
    def rate(self) -> pol.Rate:
        # fable's shape: a cache read is a tenth of fresh input.
        return pol.Rate(key="fable", fresh_in=10.0, out=50.0, cache_read=1.0, cache_write=12.5)

    def test_the_four_prices_are_charged_separately(self):
        cost = pol.call_cost(
            self.rate(), fresh_in=1000, cache_read=100_000, cache_write=0, out=500
        )
        assert cost == pytest.approx((1000 * 10 + 100_000 * 1 + 500 * 50) / 1e6)

    def test_pricing_a_warm_turn_as_fresh_would_overstate_it_tenfold(self):
        rate = self.rate()
        warm = pol.call_cost(rate, fresh_in=0, cache_read=100_000, cache_write=0, out=0)
        cold = pol.call_cost(rate, fresh_in=100_000, cache_read=0, cache_write=0, out=0)
        assert cold / warm == pytest.approx(10.0)

    def test_the_rate_table_is_read_from_the_gateways_own_file(self, tmp_path):
        table = tmp_path / "pricing.json"
        table.write_text(
            json.dumps(
                {
                    "rates": {
                        "fable": {
                            "input_per_mtok_microusd": 10_000_000,
                            "output_per_mtok_microusd": 50_000_000,
                            "cache_read_per_mtok_microusd": 1_000_000,
                            "cache_write_per_mtok_microusd": 12_500_000,
                        }
                    }
                }
            )
        )
        assert pol.Rate.table(table)["fable"] == self.rate()


class TestBilledButDiscarded:
    def test_an_abandoned_attempt_is_still_charged(self):
        """The tiers whose streams break most often are the cheap ones."""
        rate = pol.Rate(key="x", fresh_in=10.0, out=50.0, cache_read=1.0, cache_write=12.5)
        abandoned = {"fresh_in": 5000, "cache_read": 0, "cache_write": 0, "out": 200}
        assert pol.call_cost(rate, **abandoned) == pytest.approx((5000 * 10 + 200 * 50) / 1e6)


class TestUsageReading:
    def test_cached_input_reported_outside_the_prompt_count_is_still_found(self):
        """Bedrock puts it outside inputTokens; a missed split reads as a free turn."""
        reply = transport.Reply(model="x")
        transport._usage(
            reply,
            {"prompt_tokens": 9984, "completion_tokens": 100,
             "prompt_tokens_details": {"cached_tokens": 9982}},
        )
        assert reply.cached_prompt_tokens == 9982
        assert reply.fresh_prompt_tokens == 2

    def test_a_provider_that_double_counts_cannot_produce_a_negative_bill(self):
        reply = transport.Reply(model="x", prompt_tokens=100, cached_prompt_tokens=400)
        assert reply.fresh_prompt_tokens == 0

    def test_cache_writes_are_not_also_charged_as_fresh_input(self):
        """They are inside prompt_tokens and billed on their own line; counting them
        twice inflates only the long-lived threads, which is the baseline."""
        reply = transport.Reply(
            model="x", prompt_tokens=10_000, cached_prompt_tokens=6_000,
            cache_write_tokens=3_000,
        )
        assert reply.fresh_prompt_tokens == 1_000

    def test_thinking_reported_outside_the_completion_count_is_flagged(self):
        reply = transport.Reply(model="x", completion_tokens=100, reasoning_tokens=4_000)
        assert "output charge is too low" in reply.usage_anomaly

    def test_a_normal_reply_is_not_flagged(self):
        assert transport.Reply(
            model="x", completion_tokens=900, reasoning_tokens=400
        ).usage_anomaly is None

    def test_the_bedrock_spelling_is_read_too(self):
        reply = transport.Reply(model="x")
        transport._usage(reply, {"prompt_tokens": 500, "cacheReadInputTokens": 480})
        assert reply.cached_prompt_tokens == 480

class TestStreamsThatSayNothing:
    """A 200 that delivers no answer is the provider's failure, not the model's.

    Both shapes were seen on the first real sweep: a gateway that streams its failure as an
    SSE event, and one that closes the stream with nothing in it at all. Read as steps, they
    cost an episode thirty premium turns, most of its budget, and produced an empty diff that
    would have been filed as a premium model unable to fix an astropy bug.
    """

    def stream(self, *lines) -> tuple:
        class Response:
            def __init__(self, payload):
                self.payload = list(payload)

            def readline(self):
                return self.payload.pop(0) if self.payload else b""

        class Connection:
            sock = None

        return Connection(), Response([line.encode() + b"\n" for line in lines])

    def consume(self, *lines) -> transport.Reply:
        reply = transport.Reply(model="x")
        connection, response = self.stream(*lines)
        transport._consume(reply, connection, response, 0.0, transport.Endpoint(url="http://x"))
        return reply

    def test_an_error_event_is_an_error(self):
        reply = self.consume('data: {"error": {"message": "input too long"}}')
        assert reply.error and "input too long" in reply.error

    def test_a_bare_error_string_is_read_too(self):
        reply = self.consume('data: {"error": "refused"}')
        assert reply.error and "refused" in reply.error

    def test_an_ordinary_stream_is_still_ordinary(self):
        reply = self.consume(
            'data: {"choices": [{"delta": {"content": "hi"}}]}',
            'data: {"choices": [{"finish_reason": "stop"}], '
            '"usage": {"prompt_tokens": 10, "completion_tokens": 2}}',
            "data: [DONE]",
        )
        assert (reply.text, reply.error, reply.finish_reason) == ("hi", None, "stop")

    def test_an_empty_stream_ends_the_episode_rather_than_the_turn(self, monkeypatch):
        """Five empty attempts and then Unreachable: the loop records a transport failure and
        stops, instead of asking again until the token budget is gone."""
        calls = []

        class Connection:
            sock = None

            def request(self, *args, **kwargs):
                calls.append(1)

            def getresponse(self):
                class Response:
                    status = 200

                    def readline(self):
                        return b""

                    def getheader(self, _name):
                        return None

                return Response()

            def close(self):
                pass

        endpoint = transport.Endpoint(url="http://x", max_attempts=3, backoff_s=0.0)
        monkeypatch.setattr(type(endpoint), "connect", lambda self: Connection())
        with pytest.raises(transport.Unreachable) as raised:
            transport.complete(endpoint, model="m", messages=[{"role": "user", "content": "hi"}],
                               max_tokens=10)
        assert len(calls) == 3
        assert "empty stream" in str(raised.value)
        # Every attempt was billed, because every attempt read the prompt.
        assert len(raised.value.billed) == 3

    def test_a_reply_with_usage_but_no_text_is_the_model_saying_nothing(self, monkeypatch):
        """Distinct from the case above: the provider reported what the call cost, so the call
        happened and the empty answer is the model's own."""
        reply = self.consume(
            'data: {"choices": [{"finish_reason": "stop"}], '
            '"usage": {"prompt_tokens": 10, "completion_tokens": 0}}'
        )
        assert reply.error is None and reply.priced


class TestComparability:
    def test_the_transport_deciding_the_outcome_excludes_the_episode(self):
        state = pol.EpisodeState(spend_usd=0.5, transport_failures=9)
        diagnosis = loop._comparability(
            pol.POLICIES["cheap-always"](), budget(max_usd=20.0), state,
            [], "the premium tier could not be reached: empty stream",
        )
        assert diagnosis["comparable"] is False
        assert "transport" in diagnosis["not_comparable_because"]

    def test_a_third_of_turns_failing_excludes_it_too(self):
        state = pol.EpisodeState(spend_usd=0.5, transport_failures=4)
        steps = [_bare_step(i) for i in range(1, 10)]
        diagnosis = loop._comparability(
            pol.POLICIES["cheap-always"](), budget(max_usd=20.0), state, steps,
            "the agent said it was finished",
        )
        assert diagnosis["comparable"] is False

    def test_a_bill_that_is_mostly_guessed_excludes_it(self):
        state = pol.EpisodeState(spend_usd=1.0)
        steps = [_bare_step(1, usd=0.6, estimated=True), _bare_step(2, usd=0.4)]
        diagnosis = loop._comparability(
            pol.POLICIES["cheap-always"](), budget(max_usd=20.0), state, steps,
            "the agent said it was finished",
        )
        assert diagnosis["comparable"] is False
        assert "approximation" in diagnosis["not_comparable_because"]

    def test_an_ordinary_episode_is_comparable(self):
        state = pol.EpisodeState(spend_usd=1.0)
        steps = [_bare_step(1, usd=0.6), _bare_step(2, usd=0.4)]
        diagnosis = loop._comparability(
            pol.POLICIES["cheap-always"](), budget(max_usd=20.0), state, steps,
            "the agent said it was finished",
        )
        assert diagnosis["comparable"] is True
        assert diagnosis["not_comparable_because"] is None

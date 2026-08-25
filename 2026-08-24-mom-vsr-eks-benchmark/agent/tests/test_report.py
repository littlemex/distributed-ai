"""Tests for the arithmetic the pilot's conclusions are read off.

Every function here turns a directory of episodes into a number somebody will quote. A
mistake in any of them produces a number that looks fine — a cache discount that reads as
absent, a sample size off by the square of the margin, an arm credited with tasks it never
attempted — so each of those is pinned here rather than checked by eye once.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

AGENT = Path(__file__).resolve().parents[1]
if str(AGENT) not in sys.path:
    sys.path.insert(0, str(AGENT))

import report  # noqa: E402


def episode(
    instance="a",
    policy="premium-always",
    *,
    resolved=True,
    usd=1.0,
    usd_self_hosted=0.0,
    scoreable=True,
    comparable=True,
    steps=5,
    triggers=None,
    binding="the agent decided",
    step_types=None,
) -> report.Episode:
    return report.Episode(
        instance=instance,
        policy=policy,
        resolved=resolved,
        scoreable=scoreable,
        comparable=comparable,
        usd=usd,
        usd_self_hosted=usd_self_hosted,
        steps=steps,
        wall_s=10.0,
        stopped="the agent said it was finished",
        tax_usd=0.0,
        triggers=triggers or [],
        escalated_at=None,
        prompt_tokens=1000,
        completion_tokens=100,
        estimated_usd=0.0,
        context_at_first_trigger=None,
        notes=[],
        binding=binding,
        step_types=step_types or {},
    )


def write_episode(root: Path, instance: str, policy: str, steps: list[dict], **totals):
    directory = root / instance / policy
    directory.mkdir(parents=True)
    (directory / "episode.json").write_text(
        json.dumps(
            {
                "instance_id": instance,
                "policy": policy,
                "stopped_because": "the agent said it was finished",
                "wall_s": 12.0,
                "steps": steps,
                "totals": {"steps": len(steps), "usd": totals.get("usd", 1.0)},
                "per_tier": totals.get("per_tier", {}),
                "comparable": totals.get("comparable", True),
                "triggers_fired": totals.get("triggers_fired", []),
            }
        )
    )
    (directory / "score.json").write_text(
        json.dumps(
            {"resolved": totals.get("resolved", True), "scoreable": totals.get("scoreable", True)}
        )
    )


def step(index, tier="cheap", prompt=1000, cached=900, write=0):
    return {
        "index": index,
        "tier": tier,
        "prompt_tokens": prompt,
        "cached_prompt_tokens": cached,
        "cache_write_tokens": write,
        "usd": 0.1,
        "triggers": [],
    }


class TestExclusions:
    def test_an_unscoreable_episode_is_not_a_failure(self):
        """It says nothing about the policy, so counting it as a miss invents evidence."""
        episodes = [
            episode("a", resolved=True),
            episode("b", resolved=False, scoreable=False),
        ]
        row = report.per_policy(episodes)["premium-always"]
        assert row["episodes"] == 1
        assert row["rate"] == 1.0

    def test_an_episode_that_hit_the_ceiling_is_excluded(self):
        episodes = [episode("a"), episode("b", comparable=False)]
        assert report.per_policy(episodes)["premium-always"]["episodes"] == 1


class TestCostPerSolvedTask:
    def test_it_is_total_spend_over_solved_count(self):
        """Including the spend of episodes that failed: an arm that burns three episodes to
        solve one has not solved it for the price of the last one."""
        episodes = [
            episode("a", resolved=True, usd=1.0),
            episode("b", resolved=False, usd=2.0),
        ]
        assert report.per_policy(episodes)["premium-always"]["usd_per_solved"] == 3.0

    def test_the_marginal_reading_zeroes_only_the_self_hosted_tier(self):
        episodes = [episode("a", usd=3.0, usd_self_hosted=2.0)]
        row = report.per_policy(episodes)["premium-always"]
        assert row["usd_per_solved"] == 3.0
        assert row["usd_per_solved_marginal"] == 1.0

    def test_no_solved_task_is_not_a_division(self):
        episodes = [episode("a", resolved=False)]
        assert report.per_policy(episodes)["premium-always"]["usd_per_solved"] is None


class TestPairing:
    def test_only_instances_both_arms_attempted_are_paired(self):
        """A missing episode is not a loss. Counting it as one would flatter whichever arm
        ran everywhere, and in a sweep that is the arm that failed least often to submit."""
        episodes = [
            episode("a", "premium-always", resolved=True),
            episode("a", "cheap-always", resolved=False),
            episode("b", "premium-always", resolved=True),
        ]
        row = report.paired(episodes)["cheap-always"]
        assert row["n"] == 1
        assert row["b_only_baseline"] == 1

    def test_discordance_counts_both_directions(self):
        episodes = [
            episode("a", "premium-always", resolved=True),
            episode("a", "cheap-always", resolved=False),
            episode("b", "premium-always", resolved=False),
            episode("b", "cheap-always", resolved=True),
            episode("c", "premium-always", resolved=True),
            episode("c", "cheap-always", resolved=True),
        ]
        row = report.paired(episodes)["cheap-always"]
        assert (row["b_only_baseline"], row["c_only_arm"]) == (1, 1)
        assert row["discordance"] == 2 / 3
        assert row["gap_points"] == 0.0

    def test_the_baseline_is_not_compared_with_itself(self):
        episodes = [episode("a", "premium-always"), episode("a", "cheap-always")]
        assert "premium-always" not in report.paired(episodes)


class TestMcNemar:
    def test_a_one_sided_split_of_five(self):
        assert report.mcnemar_exact(5, 0) == 2 * (1 / 32)

    def test_an_even_split_is_not_evidence(self):
        assert report.mcnemar_exact(3, 3) == 1.0

    def test_no_discordant_task_is_no_test(self):
        assert report.mcnemar_exact(0, 0) is None


class TestRequiredSampleSize:
    def test_it_scales_with_the_inverse_square_of_the_margin(self):
        episodes = [
            episode(f"i{k}", "premium-always", resolved=k % 2 == 0) for k in range(10)
        ] + [episode(f"i{k}", "cheap-always", resolved=False) for k in range(10)]
        need = report.paired(episodes)["cheap-always"]["required_n"]
        # d = 0.5 here, so 6.18 * 0.5 / 0.05^2 = 1236 at five points, and the three-point
        # margin costs (5/3)^2 as much.
        assert need[5] == 1236
        assert need[3] == 3434


class TestCostRatio:
    def test_it_is_a_ratio_of_totals_not_a_mean_of_ratios(self):
        """A mean of per-task ratios lets a task that cost a cent decide the number that is
        meant to describe the workload's bill."""
        episodes = [
            episode("a", "premium-always", usd=10.0),
            episode("a", "cheap-always", usd=1.0),
            episode("b", "premium-always", usd=0.01),
            episode("b", "cheap-always", usd=0.02),
        ]
        row = report.paired(episodes)["cheap-always"]["cost_ratio"]
        assert abs(row["point"] - (1.02 / 10.01)) < 1e-9


class TestCacheShare(object):
    def test_the_first_two_calls_are_left_out(self, tmp_path):
        """Neither can be cached, so averaging them in reports a discount smaller than the
        mechanism gives — and the baseline is the arm that depends on it most."""
        write_episode(
            tmp_path,
            "a",
            "cheap-always",
            [
                step(1, cached=0),
                step(2, cached=0),
                step(3, cached=1000),
                step(4, cached=1000),
            ],
        )
        row = report.cache_pass_through(tmp_path)["cheap"]
        assert row["calls"] == 2
        assert row["mean_share"] == 1.0

    def test_a_tier_that_reports_nothing_is_visible(self, tmp_path):
        write_episode(
            tmp_path,
            "a",
            "capacity-first",
            [step(i, tier="self_hosted", cached=0) for i in range(1, 6)],
        )
        row = report.cache_pass_through(tmp_path)["self_hosted"]
        assert row["mean_share"] == 0.0
        assert row["zero_calls"] == 3

    def test_a_call_with_no_input_is_not_a_division(self, tmp_path):
        write_episode(tmp_path, "a", "cheap-always", [step(3, prompt=0, cached=0)])
        assert "cheap" not in report.cache_pass_through(tmp_path)


class TestLoad:
    def test_an_episode_with_no_score_is_not_scoreable(self, tmp_path):
        """A run whose scorer never finished must not read as a policy that failed."""
        directory = tmp_path / "a" / "cheap-always"
        directory.mkdir(parents=True)
        (directory / "episode.json").write_text(
            json.dumps(
                {
                    "instance_id": "a",
                    "policy": "cheap-always",
                    "steps": [],
                    "totals": {"steps": 0, "usd": 0.0},
                }
            )
        )
        loaded = report.load(tmp_path)
        assert loaded[0].scoreable is False
        assert loaded[0].usable is False

    def test_the_policy_configuration_is_dropped_from_the_name(self, tmp_path):
        write_episode(tmp_path, "a", "capacity-first", [step(1)])
        recorded = json.loads((tmp_path / "a/capacity-first/episode.json").read_text())
        recorded["policy"] = "capacity-first (ceiling=48, safety=70%)"
        (tmp_path / "a/capacity-first/episode.json").write_text(json.dumps(recorded))
        assert report.load(tmp_path)[0].policy == "capacity-first"

    def test_the_self_hosted_share_comes_from_the_tier_table(self, tmp_path):
        write_episode(
            tmp_path,
            "a",
            "capacity-first",
            [step(1, tier="self_hosted")],
            usd=2.0,
            per_tier={"self_hosted": {"calls": 1, "usd": 1.5}},
        )
        assert report.load(tmp_path)[0].usd_self_hosted == 1.5


class TestFlips:
    def test_only_the_same_task_and_the_same_arm_are_paired(self):
        first = [episode("a", "cheap-always", resolved=True)]
        second = [
            episode("a", "cheap-always", resolved=False),
            episode("a", "premium-always", resolved=True),
        ]
        row = report.flips(first, second)
        assert row["cheap-always"] == {"pairs": 1, "flipped": 1, "rate": 1.0}
        assert "premium-always" not in row

    def test_an_arm_absent_from_the_second_pass_is_not_a_flip(self):
        first = [episode("a", "cheap-always", resolved=True)]
        assert report.flips(first, []) == {}

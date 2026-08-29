"""Read a directory of episodes and answer the four questions the pilot exists to answer.

`docs/V3-PLAN.md` names them, and they are not "which policy won" — a 24-task pilot cannot
settle that and reporting it as if it could is how a pilot becomes a claim:

1. whether the cache discount survives the gateway, per tier, end to end;
2. what an episode costs per arm, which decides whether 250 tasks fits the budget;
3. the discordance rate `d` between the premium and cheap arms, which sets the sample size
   of the run that *can* settle it;
4. how often the escalation triggers fire, and how long the context is when they do.

Everything here is paired over instances, because the arms attempt the same tasks and the
between-task variance in a corpus like this dwarfs the between-arm variance.
"""

from __future__ import annotations

import json
import math
import random
import statistics
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path

PREMIUM_ARM = "premium-always"
# The margins the plan pre-registered, in points of single-run success rate.
MARGINS = (3, 5, 8)
# n ≈ 6.18 · d / Δ², one-sided 5% at 80% power under a McNemar structure.
POWER_CONSTANT = 6.18


@dataclass(frozen=True)
class Episode:
    instance: str
    policy: str
    resolved: bool
    scoreable: bool
    comparable: bool
    usd: float
    usd_self_hosted: float
    steps: int
    wall_s: float
    stopped: str
    tax_usd: float
    triggers: list[dict]
    escalated_at: int | None
    prompt_tokens: int
    completion_tokens: int
    estimated_usd: float
    context_at_first_trigger: int | None
    notes: list[str]
    binding: str
    step_types: dict[str, dict]

    @property
    def usable(self) -> bool:
        """Whether this episode is evidence about a policy at all.

        An unscoreable instance says nothing about the policy that attempted it, and an
        episode that hit the runaway dollar ceiling was stopped by the harness rather than by
        the policy. Both are excluded, and both are counted in the report so the exclusion is
        visible rather than silent.
        """
        return self.scoreable and self.comparable


def load(root: Path) -> list[Episode]:
    out: list[Episode] = []
    for episode_file in sorted(root.glob("*/*/episode.json")):
        episode = json.loads(episode_file.read_text())
        score_file = episode_file.with_name("score.json")
        score = json.loads(score_file.read_text()) if score_file.exists() else {}
        steps = episode["steps"]
        first_trigger = next((s for s in steps if s.get("triggers")), None)
        out.append(
            Episode(
                instance=episode["instance_id"],
                # The recorded policy name carries its configuration in parentheses, which is
                # worth keeping in the file and not in a table column.
                policy=episode["policy"].split(" ")[0],
                resolved=bool(score.get("resolved")),
                scoreable=bool(score.get("scoreable", False)) if score else False,
                comparable=bool(episode.get("comparable", True)),
                usd=episode["totals"]["usd"],
                usd_self_hosted=episode.get("per_tier", {})
                .get("self_hosted", {})
                .get("usd", 0.0),
                steps=episode["totals"]["steps"],
                wall_s=episode.get("wall_s", 0.0),
                stopped=episode.get("stopped_because", ""),
                tax_usd=episode.get("switch_tax_usd") or 0.0,
                triggers=episode.get("triggers_fired") or [],
                escalated_at=episode.get("escalated_at"),
                prompt_tokens=episode["totals"].get("prompt_tokens", 0),
                completion_tokens=episode["totals"].get("completion_tokens", 0),
                estimated_usd=sum(
                    s["usd"] for s in steps if s.get("usd_estimated")
                ),
                context_at_first_trigger=(
                    first_trigger["prompt_tokens"] if first_trigger else None
                ),
                notes=episode.get("notes") or [],
                binding=episode.get("binding_constraint", "unknown"),
                step_types=episode.get("step_types") or {},
            )
        )
    return out


def side_work(episodes: list[Episode]) -> dict[str, dict]:
    """What share of an episode is searching, reading and testing rather than patching.

    This is the ceiling on what any routing policy can save, and it is worth reading off a run
    where no routing happened: if reading and searching are a tenth of the bill, moving them to
    a cheaper tier cannot save much however good that tier turns out to be. Shares of money,
    not of turns — a turn is not the unit anybody pays in.
    """
    out: dict[str, dict] = {}
    for policy in sorted({e.policy for e in episodes if e.usable}):
        totals: dict[str, float] = defaultdict(float)
        spent = 0.0
        for episode in (e for e in episodes if e.usable and e.policy == policy):
            for kind, row in episode.step_types.items():
                totals[kind] += row.get("usd", 0.0)
                spent += row.get("usd", 0.0)
        if not spent:
            continue
        out[policy] = {
            "usd": spent,
            "shares": {kind: value / spent for kind, value in sorted(totals.items())},
        }
    return out


# --- the four questions ------------------------------------------------------------------


def cache_pass_through(root: Path) -> dict[str, dict]:
    """Per tier: how much of the input a provider says it served from cache.

    Counted from the third call of an episode onwards. The first two cannot be cached — there
    is no prefix yet, and a provider that has just written one has not yet read it — so
    including them would report a lower discount than the mechanism actually gives and make
    the baseline look cheaper to run than it is.
    """
    per_tier: dict[str, list[float]] = defaultdict(list)
    writes: dict[str, int] = defaultdict(int)
    for episode_file in sorted(root.glob("*/*/episode.json")):
        for step in json.loads(episode_file.read_text())["steps"]:
            if step["index"] < 3 or not step.get("prompt_tokens"):
                continue
            per_tier[step["tier"]].append(
                step.get("cached_prompt_tokens", 0) / step["prompt_tokens"]
            )
            writes[step["tier"]] += step.get("cache_write_tokens", 0) or 0
    return {
        tier: {
            "calls": len(shares),
            "mean_share": statistics.fmean(shares),
            "max_share": max(shares),
            "zero_calls": sum(1 for s in shares if s == 0),
            "cache_write_tokens": writes[tier],
        }
        for tier, shares in sorted(per_tier.items())
    }


def per_policy(episodes: list[Episode]) -> dict[str, dict]:
    by_policy: dict[str, list[Episode]] = defaultdict(list)
    for episode in episodes:
        if episode.usable:
            by_policy[episode.policy].append(episode)
    out = {}
    for policy, group in sorted(by_policy.items()):
        solved = [e for e in group if e.resolved]
        spent = sum(e.usd for e in group)
        # The self-hosted machine is already running and bills wall-clock, so its marginal
        # cost for one more episode is zero. Both readings are reported because they answer
        # different questions: what the experiment consumed, and what an operator would pay
        # for the next episode on hardware already paid for.
        marginal = sum(e.usd - e.usd_self_hosted for e in group)
        out[policy] = {
            "episodes": len(group),
            "solved": len(solved),
            "rate": len(solved) / len(group),
            "usd_total": spent,
            "usd_median": statistics.median([e.usd for e in group]),
            "usd_per_solved": spent / len(solved) if solved else None,
            "usd_per_solved_marginal": marginal / len(solved) if solved else None,
            "steps_median": statistics.median([e.steps for e in group]),
            "wall_median": statistics.median([e.wall_s for e in group]),
            "estimated_usd": sum(e.estimated_usd for e in group),
            "tokens_median": statistics.median(
                [e.prompt_tokens + e.completion_tokens for e in group]
            ),
            # What stopped the episodes, which decides whether the budget or the policy is
            # being measured. An arm whose episodes mostly end on a limit is being described
            # by the limit.
            "binding": dict(
                sorted(
                    Counter(e.binding for e in group).items(), key=lambda kv: -kv[1]
                )
            ),
        }
    return out


def paired(episodes: list[Episode], baseline: str = PREMIUM_ARM) -> dict[str, dict]:
    """Discordance against the baseline, task by task, and what it implies for n.

    `b` is tasks the baseline solved and the arm did not, `c` the reverse. McNemar uses only
    those: a task both arms solve and a task neither solves carry no information about the
    difference, which is why the sample size follows `d = (b + c) / n` rather than either
    arm's success rate.
    """
    by_instance: dict[str, dict[str, Episode]] = defaultdict(dict)
    for episode in episodes:
        if episode.usable:
            by_instance[episode.instance][episode.policy] = episode

    out = {}
    for policy in sorted({e.policy for e in episodes if e.usable} - {baseline}):
        pairs = [
            (row[baseline], row[policy])
            for row in by_instance.values()
            if baseline in row and policy in row
        ]
        if not pairs:
            continue
        b = sum(1 for base, arm in pairs if base.resolved and not arm.resolved)
        c = sum(1 for base, arm in pairs if arm.resolved and not base.resolved)
        n = len(pairs)
        d = (b + c) / n
        out[policy] = {
            "n": n,
            "b_only_baseline": b,
            "c_only_arm": c,
            "discordance": d,
            "gap_points": (b - c) / n * 100,
            "p_exact": mcnemar_exact(b, c),
            "gap_upper_95": paired_gap_upper_bound(pairs),
            "required_n": {
                margin: math.ceil(POWER_CONSTANT * d / (margin / 100) ** 2)
                if d
                else None
                for margin in MARGINS
            },
            "cost_ratio": cost_ratio(pairs),
        }
    return out


def mcnemar_exact(b: int, c: int) -> float | None:
    """Two-sided exact test: given b + c discordant tasks, is the split fair?

    Exact rather than the chi-square approximation because a 24-task pilot produces single
    digit discordant counts, where the approximation is not to be trusted.
    """
    n = b + c
    if n == 0:
        return None
    k = min(b, c)
    tail = sum(math.comb(n, i) for i in range(k + 1)) / 2**n
    return min(1.0, 2 * tail)


def paired_gap_upper_bound(
    pairs: list[tuple[Episode, Episode]], *, seed: int = 20260826, draws: int = 10_000
) -> float:
    """One-sided 95% upper bound on (baseline − arm) success, in points, by paired bootstrap.

    Resampling tasks and not calls: the task is the unit the arms share. Reported as an upper
    bound because the claim being tested is one-sided — the arm is non-inferior if the gap
    cannot be worse than the margin, and a two-sided interval answers a question nobody asked.
    """
    rng = random.Random(seed)
    n = len(pairs)
    gaps = []
    for _ in range(draws):
        sample = [pairs[rng.randrange(n)] for _ in range(n)]
        gaps.append(
            sum(1 for base, arm in sample if base.resolved) / n * 100
            - sum(1 for base, arm in sample if arm.resolved) / n * 100
        )
    gaps.sort()
    return gaps[int(0.95 * (draws - 1))]


def cost_ratio(
    pairs: list[tuple[Episode, Episode]], *, seed: int = 20260826, draws: int = 10_000
) -> dict:
    """Arm spend over baseline spend on the same tasks, with a paired bootstrap interval.

    A ratio of totals rather than a mean of per-task ratios: the quantity an operator cares
    about is the bill for the whole workload, and a mean of ratios lets the cheapest task in
    the corpus dominate a number that is meant to describe the expensive ones.
    """
    rng = random.Random(seed)
    n = len(pairs)
    base_total = sum(base.usd for base, _ in pairs)
    arm_total = sum(arm.usd for _, arm in pairs)
    if not base_total:
        return {"point": None, "low": None, "high": None}
    ratios = []
    for _ in range(draws):
        sample = [pairs[rng.randrange(n)] for _ in range(n)]
        denominator = sum(base.usd for base, _ in sample)
        if denominator:
            ratios.append(sum(arm.usd for _, arm in sample) / denominator)
    ratios.sort()
    return {
        "point": arm_total / base_total,
        "low": ratios[int(0.025 * (len(ratios) - 1))],
        "high": ratios[int(0.975 * (len(ratios) - 1))],
    }


def triggers(episodes: list[Episode]) -> dict[str, dict]:
    """How often an escalation trigger fired, and how long the context was when it did.

    The second number is the one the switch-tax inequality needs: the tax is paid on the
    prefix as it stands at the moment of the switch, so a trigger that fires at 4k tokens and
    one that fires at 60k are different mechanisms wearing the same name.
    """
    out = {}
    for policy in sorted({e.policy for e in episodes}):
        group = [e for e in episodes if e.policy == policy and e.usable]
        fired = [e for e in group if e.triggers]
        if not group:
            continue
        contexts = [
            e.context_at_first_trigger for e in fired if e.context_at_first_trigger
        ]
        reasons: dict[str, int] = defaultdict(int)
        for episode in fired:
            for entry in episode.triggers:
                for reason in entry.get("reasons", []):
                    reasons[reason] += 1
        out[policy] = {
            "episodes": len(group),
            "fired": len(fired),
            "first_step_median": statistics.median(
                [e.triggers[0]["step"] for e in fired]
            )
            if fired
            else None,
            "context_median": statistics.median(contexts) if contexts else None,
            "tax_mean": statistics.fmean([e.tax_usd for e in group if e.tax_usd])
            if any(e.tax_usd for e in group)
            else 0.0,
            "reasons": dict(sorted(reasons.items(), key=lambda kv: -kv[1])),
        }
    return out


def flips(first: list[Episode], second: list[Episode]) -> dict[str, dict]:
    """How often the same arm on the same task changes its answer between two passes.

    v1 found that half the variance in a paired comparison was re-asking rather than the
    models. If that holds here, power is bought more cheaply by re-running tasks than by
    adding them, and this is the number that decides which.
    """
    index = {(e.instance, e.policy): e for e in second if e.usable}
    out: dict[str, dict] = {}
    for episode in first:
        if not episode.usable:
            continue
        other = index.get((episode.instance, episode.policy))
        if other is None:
            continue
        row = out.setdefault(episode.policy, {"pairs": 0, "flipped": 0})
        row["pairs"] += 1
        row["flipped"] += int(episode.resolved != other.resolved)
    for row in out.values():
        row["rate"] = row["flipped"] / row["pairs"] if row["pairs"] else None
    return out


# --- rendering ---------------------------------------------------------------------------


def render(
    episodes: list[Episode],
    root: Path,
    strata: dict[str, tuple[str, str]] | None = None,
    second_pass: list[Episode] | None = None,
) -> str:
    lines: list[str] = []
    usable = [e for e in episodes if e.usable]
    excluded = [e for e in episodes if not e.usable]
    instances = sorted({e.instance for e in episodes})
    policies = sorted({e.policy for e in episodes})

    lines += [
        "# Agent pilot: what the episodes say",
        "",
        f"{len(episodes)} episodes over {len(instances)} instances and {len(policies)} "
        f"policies, of which {len(usable)} are usable evidence.",
        "",
    ]
    if excluded:
        lines += ["Excluded, with the reason recorded before the results were seen:", ""]
        for episode in excluded:
            why = (
                "not scoreable"
                if not episode.scoreable
                else "hit the runaway ceiling"
            )
            lines.append(f"- `{episode.instance}` / `{episode.policy}`: {why}")
        lines.append("")

    lines += [
        "## What an episode costs, and how often it works",
        "",
        "| Policy | Solved | Rate | Median $ | $ per solved | $ per solved, marginal "
        "| Median steps | Median tokens | Median wall | What stopped them |",
        "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    for policy, row in per_policy(episodes).items():
        per_solved = (
            f"${row['usd_per_solved']:.3f}" if row["usd_per_solved"] else "none solved"
        )
        marginal = (
            f"${row['usd_per_solved_marginal']:.3f}"
            if row["usd_per_solved_marginal"] is not None
            else "-"
        )
        binding = ", ".join(f"{k} x{v}" for k, v in row["binding"].items())
        lines.append(
            f"| `{policy}` | {row['solved']}/{row['episodes']} | {row['rate']:.0%} "
            f"| ${row['usd_median']:.3f} | {per_solved} | {marginal} "
            f"| {row['steps_median']:.0f} | {row['tokens_median']:,.0f} "
            f"| {row['wall_median']:.0f}s | {binding} |"
        )
    lines += [
        "",
        "The marginal column prices the self-hosted tier at zero, which is what one more "
        "episode on a machine that is already running and already billed actually costs. "
        "The metered column is what the experiment consumed at the rate measured at the "
        "throughput knee. Neither is wrong; they answer different questions.",
        "",
    ]

    work = side_work(episodes)
    if work:
        kinds = sorted({kind for row in work.values() for kind in row["shares"]})
        lines += [
            "## Where the money goes inside an episode",
            "",
            "| Policy | " + " | ".join(kinds) + " |",
            "| --- | " + " | ".join("---" for _ in kinds) + " |",
        ]
        for policy, row in work.items():
            cells = [
                f"{row['shares'].get(kind, 0.0):.0%}" if kind in row["shares"] else "-"
                for kind in kinds
            ]
            lines.append(f"| `{policy}` | " + " | ".join(cells) + " |")
        lines += [
            "",
            "Shares of spend, not of turns. This is the ceiling on what any routing policy can "
            "save: a step type that is a tenth of the bill cannot be moved to a cheaper tier "
            "for more than a tenth, whatever that tier turns out to be worth.",
            "",
        ]

    lines += [
        "## Whether the cache discount survives the gateway",
        "",
        "| Tier | Calls (3rd onwards) | Mean cached share of input | Best | Calls with none |",
        "| --- | --- | --- | --- | --- |",
    ]
    for tier, row in cache_pass_through(root).items():
        lines.append(
            f"| `{tier}` | {row['calls']} | {row['mean_share']:.0%} "
            f"| {row['max_share']:.0%} | {row['zero_calls']} |"
        )
    lines.append("")

    lines += [
        f"## Discordance against `{PREMIUM_ARM}`, and the n it implies",
        "",
        "| Arm | n | Only baseline | Only arm | d | Gap (pts) | Exact p | Gap upper 95% "
        "| n at 3 pts | n at 5 pts | n at 8 pts | Spend vs baseline |",
        "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    for policy, row in paired(episodes).items():
        need = row["required_n"]
        ratio = row["cost_ratio"]
        ratio_text = (
            f"{ratio['point']:.2f}x [{ratio['low']:.2f}, {ratio['high']:.2f}]"
            if ratio["point"] is not None
            else "-"
        )
        # No discordant task means no test and no sample size: the arms agreed everywhere,
        # which at this size is a statement about the tasks and not about the arms.
        p_text = f"{row['p_exact']:.3f}" if row["p_exact"] is not None else "no discordance"
        lines.append(
            f"| `{policy}` | {row['n']} | {row['b_only_baseline']} | {row['c_only_arm']} "
            f"| {row['discordance']:.2f} | {row['gap_points']:+.1f} "
            f"| {p_text} | {row['gap_upper_95']:+.1f} "
            f"| {need[3] or '-'} | {need[5] or '-'} | {need[8] or '-'} | {ratio_text} |"
        )
    lines += [
        "",
        "`n at Δ` is the paired sample size a one-sided 5% test needs for 80% power at that "
        "margin, from the discordance measured here. It is what the pilot exists to supply; "
        "the gap column at this size is a description of 24 tasks and not a verdict.",
        "",
    ]

    lines += [
        "## Triggers",
        "",
        "| Policy | Fired | First fire (step) | Context at first fire | Mean switch tax "
        "| Reasons |",
        "| --- | --- | --- | --- | --- | --- |",
    ]
    for policy, row in triggers(episodes).items():
        reasons = ", ".join(f"{k} x{v}" for k, v in row["reasons"].items()) or "-"
        first = row["first_step_median"]
        context = f"{row['context_median']:,.0f}" if row["context_median"] else "-"
        lines.append(
            f"| `{policy}` | {row['fired']}/{row['episodes']} "
            f"| {first if first is not None else '-'} | {context} "
            f"| ${row['tax_mean']:.3f} | {reasons} |"
        )
    lines.append("")

    if second_pass:
        lines += [
            "## Re-run flip rate",
            "",
            "| Policy | Pairs | Flipped | Rate |",
            "| --- | --- | --- | --- |",
        ]
        for policy, row in sorted(flips(episodes, second_pass).items()):
            lines.append(
                f"| `{policy}` | {row['pairs']} | {row['flipped']} | {row['rate']:.0%} |"
            )
        lines.append("")

    if strata:
        lines += ["## By difficulty", "", "| Difficulty | " + " | ".join(f"`{p}`" for p in policies) + " |",
                  "| --- | " + " | ".join("---" for _ in policies) + " |"]
        by_band: dict[str, dict[str, list[Episode]]] = defaultdict(lambda: defaultdict(list))
        for episode in usable:
            band = strata.get(episode.instance, ("", "unknown"))[1]
            by_band[band][episode.policy].append(episode)
        for band in sorted(by_band):
            cells = []
            for policy in policies:
                group = by_band[band][policy]
                cells.append(
                    f"{sum(1 for e in group if e.resolved)}/{len(group)}" if group else "-"
                )
            lines.append(f"| {band} | " + " | ".join(cells) + " |")
        lines.append("")

    lines += ["## Per-instance", "", "| Instance | " + " | ".join(f"`{p}`" for p in policies) + " |",
              "| --- | " + " | ".join("---" for _ in policies) + " |"]
    index = {(e.instance, e.policy): e for e in episodes}
    for instance in instances:
        cells = []
        for policy in policies:
            episode = index.get((instance, policy))
            if episode is None:
                cells.append("-")
            elif not episode.usable:
                cells.append("excl")
            else:
                cells.append(("yes" if episode.resolved else "no") + f" ${episode.usd:.2f}")
        lines.append(f"| `{instance}` | " + " | ".join(cells) + " |")
    lines.append("")

    priced_by_estimate = sum(e.estimated_usd for e in episodes)
    if priced_by_estimate:
        lines += [
            f"Of the total, ${priced_by_estimate:.3f} was priced by approximation rather "
            "than from a usage block, on steps whose stream broke before reporting one.",
            "",
        ]
    return "\n".join(lines)


def main() -> None:
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    here = Path(__file__).resolve().parent
    parser.add_argument("--results", type=Path, default=here.parent / "results/episodes")
    parser.add_argument(
        "--pass2", type=Path, default=None, help="a second pass, for the flip rate"
    )
    parser.add_argument("--out", type=Path, default=None)
    parser.add_argument(
        "--strata",
        type=Path,
        default=Path.home() / ".cache/swebench-verified.json",
        help="the dataset cache, for the per-difficulty table; skipped if absent",
    )
    args = parser.parse_args()

    episodes = load(args.results)
    if not episodes:
        raise SystemExit(f"[FAIL] no episodes under {args.results}")
    second = load(args.pass2) if args.pass2 else None

    strata = None
    if args.strata and args.strata.exists():
        import dataset

        strata = {
            i.instance_id: (i.repo, i.difficulty) for i in dataset.load(args.strata)
        }

    text = render(episodes, args.results, strata, second)
    if args.out:
        args.out.write_text(text)
        print(f"[OK] {len(episodes)} episodes -> {args.out}")
    else:
        print(text)


if __name__ == "__main__":
    main()

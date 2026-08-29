#!/usr/bin/env python3
"""Is "run cheap, escalate at the important step" arithmetically possible?

    ./switch_economics.py --premium fable --cheap gpt-5.6-terra

Run before spending anything on an agentic experiment, because the answer might be no
on the rate table alone. In a long session almost every input token is a prefix-cache
hit, and a cache hit costs a tenth of a fresh one. Two consequences pull against each
other:

* Staying on the premium model is far cheaper than its list price suggests — the
  baseline this experiment wants to beat is stronger than it looks.
* Switching models mid-session throws the prefix cache away. The model being escalated
  to has never seen the conversation, so it pays the *fresh* input price on everything
  accumulated so far. That is the switch tax, and it grows with how late the escalation
  happens.

So the strategy earns its keep only when the savings from the cheap steps exceed the
tax. This script draws that line from the gateway's own rate table, so the numbers are
the ones that will actually be billed rather than a vendor's headline price.

The session model is deliberately simple and stated rather than fitted: a session of
`steps` turns, context growing by `growth` tokens per turn (the previous output plus a
tool result), `output` tokens generated per turn. At each turn a model that has been
running pays the cache-read price on the prefix it already established and the fresh
input price on that turn's growth. A model that has just been switched to pays the
fresh price on the whole accumulated prefix once.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent


@dataclass(frozen=True)
class Rate:
    """What a million tokens costs, in each of the four ways they can be billed."""

    name: str
    fresh_in: float
    out: float
    cache_read: float
    cache_write: float

    @classmethod
    def load(cls, defaults: Path, key: str) -> "Rate":
        rates = json.load((defaults / "pricing.json").open())["rates"]
        if key not in rates:
            raise SystemExit(
                f"[FAIL] no rate called {key!r}; the table has {sorted(rates)}"
            )
        entry = rates[key]
        return cls(
            name=key,
            fresh_in=entry["input_per_mtok_microusd"] / 1e6,
            out=entry["output_per_mtok_microusd"] / 1e6,
            cache_read=entry["cache_read_per_mtok_microusd"] / 1e6,
            cache_write=entry["cache_write_per_mtok_microusd"] / 1e6,
        )


@dataclass(frozen=True)
class Session:
    steps: int = 60
    start_context: int = 20_000
    growth: int = 3_000
    output: int = 500

    def context_before(self, step: int) -> int:
        """Tokens already in the conversation when `step` (1-based) begins."""
        return self.start_context + self.growth * (step - 1)


def cost_of_run(
    rate: Rate, session: Session, first: int, last: int, *, warm: bool
) -> float:
    """What steps `first`..`last` cost on one model, in dollars.

    `warm` is the whole question. A model that has been running since the start has the
    conversation in its cache and pays a tenth for it; a model that has just been
    escalated to pays the fresh price on everything accumulated, once.
    """
    if last < first:
        return 0.0
    total = 0.0
    if not warm:
        # The switch tax: establish the prefix at the fresh price. Charged as a cache
        # write, which is what a provider bills when it stores the prefix for reuse and
        # is the more expensive of the two readings.
        total += session.context_before(first) / 1e6 * rate.cache_write
    for step in range(first, last + 1):
        prefix = session.context_before(step)
        if step > first or warm:
            total += prefix / 1e6 * rate.cache_read
        total += session.growth / 1e6 * rate.fresh_in
        total += session.output / 1e6 * rate.out
    return total


def escalation_break_even(
    premium: Rate, cheap: Rate, session: Session
) -> dict[str, float]:
    """The latest step at which escalating still beats having used premium throughout.

    Reported as a step index and as the share of the session that has to run on the
    cheap model before the switch pays for itself.
    """
    baseline = cost_of_run(premium, session, 1, session.steps, warm=True)
    cheap_only = cost_of_run(cheap, session, 1, session.steps, warm=True)
    rows = []
    for switch_at in range(1, session.steps + 1):
        mixed = cost_of_run(cheap, session, 1, switch_at - 1, warm=True) + cost_of_run(
            premium, session, switch_at, session.steps, warm=False
        )
        rows.append((switch_at, mixed))
    cheapest_switch, cheapest_cost = min(rows, key=lambda r: r[1])
    wins = [step for step, cost in rows if cost < baseline]
    return {
        "baseline": baseline,
        "cheap_only": cheap_only,
        "best_switch_step": cheapest_switch,
        "best_switch_cost": cheapest_cost,
        "best_saving": 1 - cheapest_cost / baseline if baseline else 0.0,
        "earliest_win": min(wins) if wins else 0,
        "latest_win": max(wins) if wins else 0,
        "switch_tax_at_half": session.context_before(session.steps // 2)
        / 1e6
        * premium.cache_write,
        "premium_step_warm": (
            session.context_before(session.steps // 2) / 1e6 * premium.cache_read
            + session.growth / 1e6 * premium.fresh_in
            + session.output / 1e6 * premium.out
        ),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--premium", default="fable", help="rate key of the baseline model")
    parser.add_argument("--cheap", nargs="+", default=["gpt-5.6-terra", "grok", "haiku"])
    parser.add_argument("--steps", type=int, default=60)
    parser.add_argument("--start-context", type=int, default=20_000)
    parser.add_argument("--growth", type=int, default=3_000)
    parser.add_argument("--output", type=int, default=500)
    parser.add_argument(
        "--defaults",
        type=Path,
        default=Path(os.environ.get("STRATOCLAVE_DEFAULTS", "")),
        help="the gateway's models/pricing directory",
    )
    args = parser.parse_args(argv)
    if not args.defaults or not args.defaults.exists():
        raise SystemExit("[FAIL] STRATOCLAVE_DEFAULTS (or --defaults) is required")

    session = Session(
        steps=args.steps,
        start_context=args.start_context,
        growth=args.growth,
        output=args.output,
    )
    premium = Rate.load(args.defaults, args.premium)
    print(
        f"[INFO] session: {session.steps} steps, context {session.start_context:,} -> "
        f"{session.context_before(session.steps):,} tokens, {session.output} output/step"
    )
    print(
        f"[INFO] {premium.name}: fresh in ${premium.fresh_in:.2f}/Mtok, cache read "
        f"${premium.cache_read:.3f} ({premium.fresh_in / premium.cache_read:.0f}x cheaper), "
        f"cache write ${premium.cache_write:.2f}, out ${premium.out:.2f}"
    )

    for key in args.cheap:
        cheap = Rate.load(args.defaults, key)
        r = escalation_break_even(premium, cheap, session)
        print(f"\n== {premium.name} baseline vs {cheap.name} with one escalation ==")
        print(f"    premium all the way            ${r['baseline']:.4f}")
        print(f"    cheap all the way              ${r['cheap_only']:.4f}"
              f"   ({1 - r['cheap_only'] / r['baseline']:.0%} less, quality unknown)")
        print(
            f"    best switch point              step {r['best_switch_step']} of "
            f"{session.steps} -> ${r['best_switch_cost']:.4f} "
            f"({r['best_saving']:.0%} less)"
        )
        if r["earliest_win"]:
            print(
                f"    escalating beats the baseline  steps {r['earliest_win']}"
                f"-{r['latest_win']} ({r['latest_win'] / session.steps:.0%} of the way in "
                "at the latest)"
            )
        else:
            print("    escalating never beats the baseline at any switch point")
        print(
            f"    switch tax at the midpoint     ${r['switch_tax_at_half']:.4f}"
            f"   = {r['switch_tax_at_half'] / r['premium_step_warm']:.1f} warm premium steps"
        )
    print(
        "\n[INFO] the tax is paid once per switch, so a trigger that fires k times pays it "
        "k times; a policy that escalates and returns pays it on every return too."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

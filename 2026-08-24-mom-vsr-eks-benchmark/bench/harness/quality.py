"""Whether a finished run can be compared at all.

Separate from `runner`, which counts what happened, and from `collect`, which prints.
The thresholds here are measurement policy — the line between "this arm was worse" and
"this arm was measured differently" — and the same policy has to be readable from the
analysis side, which must not import a CLI to get at it.

Every finding here describes a way for a results file to look complete while meaning
something other than it appears to.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from . import runner

# A truncation rate above this on any arm means the completion budget, and not the
# model, decided part of that arm's score.
TRUNCATION_RATE = 0.02

# A spread this wide between arms' failure rates means they were not asked the same
# questions. Paired comparisons assume they were.
FAILURE_SPREAD = 0.02


@dataclass(frozen=True)
class Finding:
    """One reason to distrust a comparison, with the arms it applies to."""

    headline: str
    rows: list[tuple[str, str]] = field(default_factory=list)


def review(stats: runner.RunStats) -> list[Finding]:
    """What about this run would make a comparison mean something else."""
    findings = []

    if stats.retired_arms:
        findings.append(
            Finding(
                headline=(
                    f"{len(stats.retired_arms)} arms were retired mid-run: the provider "
                    "rejected the effort level, so the arm stopped existing and its "
                    "remaining questions were not attempted. Scoring it on the subset it "
                    "did answer would compare arms over different question sets."
                ),
                rows=[
                    (arm, reason[:90]) for arm, reason in sorted(stats.retired_arms.items())
                ],
            )
        )

    rates = stats.failure_asymmetry()
    if rates and max(rates.values()) - min(rates.values()) > FAILURE_SPREAD:
        findings.append(
            Finding(
                headline=(
                    "the arms did not fail alike, and a failed cell counts as collected: "
                    "the arms below were asked fewer questions than the others, which is "
                    "the assumption every paired comparison here rests on. Collect the "
                    "missing cells into a new file before scoring."
                ),
                rows=[
                    (
                        arm,
                        f"{stats.failed_by_arm.get(arm, 0)}/"
                        f"{stats.failed_by_arm.get(arm, 0) + stats.scored_by_arm.get(arm, 0)}"
                        f"  {rate:6.2%}",
                    )
                    for arm, rate in sorted(rates.items(), key=lambda kv: -kv[1])[:8]
                ],
            )
        )

    over = {
        arm: bucket
        for arm, bucket in stats.truncation_rates().items()
        if bucket["rate"] > TRUNCATION_RATE
    }
    if over:
        findings.append(
            Finding(
                headline=(
                    f"{len(over)} arms hit the completion budget more often than "
                    f"{TRUNCATION_RATE:.0%} in this run. A cap costs nothing for the arms "
                    "that stay under it, so raise --max-tokens and collect these again "
                    "into a new file rather than scoring a cut-off answer as a wrong one."
                ),
                rows=[
                    (
                        arm,
                        f"{int(bucket['truncated'])}/{int(bucket['scored'])}"
                        f"  {bucket['rate']:6.2%}",
                    )
                    for arm, bucket in sorted(over.items(), key=lambda kv: -kv[1]["rate"])
                ],
            )
        )

    return findings

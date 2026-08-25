"""Uncertainty for paired arms.

Every arm answers the same questions, so the comparisons are paired and the right
interval is a paired one: resample questions, not answers. An unpaired interval
would carry the variance of question difficulty, which is identical across arms
and therefore not evidence about the arms.

Resampling is **stratified by category, with the category sizes held fixed**. That
matches what this benchmark actually is: the category mix is set by design, by
sampling a chosen number of questions per category, so it is not one draw from a
population of mixes. Resampling categories themselves — a cluster bootstrap — would
be answering a question nobody asked ("what if the benchmark had a different
subject mix"), and with only seven categories its intervals would be badly
calibrated on top of that.

The other thing this module exists to prevent is reading a wide interval as
agreement. An interval that contains zero means the data cannot resolve the
difference, not that the difference is absent, and at these sample sizes it will
contain zero even when the true difference is a couple of points. So a claim of
"as accurate, for less money" has to come from `non_inferiority`, which asks the
one-sided question directly against a margin fixed in advance.
"""

from __future__ import annotations

import math
import random
from dataclasses import dataclass
from typing import Callable, Sequence


@dataclass(frozen=True)
class Interval:
    point: float
    low: float
    high: float

    def excludes_zero(self) -> bool:
        return self.low > 0 or self.high < 0

    def __str__(self) -> str:
        return f"{self.point:+.4f} CI[{self.low:+.4f},{self.high:+.4f}]"


def paired_bootstrap(
    units: Sequence[object],
    statistic: Callable[[Sequence[object]], float],
    *,
    rounds: int = 2000,
    alpha: float = 0.05,
    seed: int = 12345,
    strata: Sequence[str] | None = None,
    one_sided: bool = False,
) -> Interval:
    """Percentile interval for a statistic of paired per-question records.

    `units` are the paired records — one entry per question, carrying every arm's
    outcome for it. `strata` labels each unit; when given, questions are resampled
    within each stratum and every stratum keeps its original size, which is the
    inference that matches a benchmark whose subject mix was chosen rather than
    sampled.

    `one_sided` returns `[low, +inf)`, for asking whether a difference is above a
    margin rather than whether it is distinguishable from zero.
    """
    if not units:
        raise ValueError("no units to resample")
    point = statistic(units)
    rng = random.Random(seed)
    draws = []

    if strata is None:
        n = len(units)
        for _ in range(rounds):
            sample = [units[rng.randrange(n)] for _ in range(n)]
            draws.append(statistic(sample))
    else:
        if len(strata) != len(units):
            raise ValueError("strata must label every unit")
        grouped: dict[str, list[object]] = {}
        for label, unit in zip(strata, units):
            grouped.setdefault(label, []).append(unit)
        for _ in range(rounds):
            sample: list[object] = []
            for group in grouped.values():
                size = len(group)
                sample.extend(group[rng.randrange(size)] for _ in range(size))
            draws.append(statistic(sample))

    draws.sort()
    if one_sided:
        return Interval(
            point=point,
            low=draws[int(alpha * (len(draws) - 1))],
            high=float("inf"),
        )
    low = draws[int((alpha / 2) * (len(draws) - 1))]
    high = draws[int((1 - alpha / 2) * (len(draws) - 1))]
    return Interval(point=point, low=low, high=high)


def bootstrap_p_value(
    units: Sequence[object],
    statistic: Callable[[Sequence[object]], float],
    *,
    rounds: int = 2000,
    seed: int = 12345,
    strata: Sequence[str] | None = None,
) -> float:
    """Two-sided bootstrap p-value for "the statistic is zero".

    The fraction of resamples whose statistic falls on the far side of zero from
    the point estimate, doubled, with the usual +1 so a p-value is never exactly
    zero. A real number is needed here because a multiple-comparison correction
    ranks p-values: feeding it a 0-or-1 stand-in derived from whether an interval
    crossed zero would make the correction do nothing at all.
    """
    if not units:
        return 1.0
    point = statistic(units)
    rng = random.Random(seed)
    draws = []

    if strata is None:
        n = len(units)
        for _ in range(rounds):
            draws.append(statistic([units[rng.randrange(n)] for _ in range(n)]))
    else:
        grouped: dict[str, list[object]] = {}
        for label, unit in zip(strata, units):
            grouped.setdefault(label, []).append(unit)
        for _ in range(rounds):
            sample: list[object] = []
            for group in grouped.values():
                size = len(group)
                sample.extend(group[rng.randrange(size)] for _ in range(size))
            draws.append(statistic(sample))

    if point >= 0:
        tail = sum(1 for d in draws if d <= 0)
    else:
        tail = sum(1 for d in draws if d >= 0)
    return min(1.0, 2 * (tail + 1) / (len(draws) + 1))


@dataclass(frozen=True)
class NonInferiority:
    """Whether an arm is no worse than a reference by more than a fixed margin."""

    delta: float
    margin: float
    lower_bound: float
    passes: bool
    superior: bool

    def verdict(self) -> str:
        if self.superior:
            return f"better by more than 0 (lower bound {self.lower_bound:+.4f})"
        if self.passes:
            return f"no worse by more than {self.margin:.3f} (lower bound {self.lower_bound:+.4f})"
        return f"cannot rule out losing more than {self.margin:.3f} (lower bound {self.lower_bound:+.4f})"

    def __str__(self) -> str:
        return self.verdict()


def non_inferiority(
    units: Sequence[object],
    statistic: Callable[[Sequence[object]], float],
    *,
    margin: float,
    rounds: int = 2000,
    alpha: float = 0.05,
    seed: int = 12345,
    strata: Sequence[str] | None = None,
) -> NonInferiority:
    """Test `delta > -margin` one-sided, rather than `delta != 0`.

    This is the test the headline claim needs. "The interval contains zero" is
    absence of evidence; at a few hundred questions per fold it will contain zero
    even when the truth is a two-point loss, so reading it as equivalence would
    sell a real regression as a saving. The margin has to be chosen before the
    fold is opened, and it is the same margin the assignment rule was allowed to
    trade away.
    """
    interval = paired_bootstrap(
        units, statistic, rounds=rounds, alpha=alpha, seed=seed, strata=strata,
        one_sided=True,
    )
    return NonInferiority(
        delta=interval.point,
        margin=margin,
        lower_bound=interval.low,
        passes=interval.low > -margin,
        superior=interval.low > 0,
    )


@dataclass(frozen=True)
class McNemar:
    """Discordant pairs between two arms on the same questions."""

    only_a: int
    only_b: int
    both: int
    neither: int
    statistic: float
    p_value: float

    @property
    def discordant(self) -> int:
        return self.only_a + self.only_b


def mcnemar(a_correct: Sequence[bool], b_correct: Sequence[bool]) -> McNemar:
    """Exact-ish test on the questions where the two arms disagree.

    The concordant pairs carry no information about which arm is better, which is
    why an unpaired proportion test on the same data is both weaker and wrong
    here. Uses the binomial tail when the discordant count is small, where the
    chi-square approximation is unreliable.
    """
    if len(a_correct) != len(b_correct):
        raise ValueError("arms must have answered the same questions")
    only_a = sum(1 for a, b in zip(a_correct, b_correct) if a and not b)
    only_b = sum(1 for a, b in zip(a_correct, b_correct) if b and not a)
    both = sum(1 for a, b in zip(a_correct, b_correct) if a and b)
    neither = sum(1 for a, b in zip(a_correct, b_correct) if not a and not b)
    n = only_a + only_b

    if n == 0:
        return McNemar(only_a, only_b, both, neither, statistic=0.0, p_value=1.0)

    if n < 25:
        smaller = min(only_a, only_b)
        tail = sum(math.comb(n, k) for k in range(smaller + 1)) / (2**n)
        p_value = min(1.0, 2 * tail)
        statistic = float(smaller)
    else:
        # Continuity-corrected chi-square with one degree of freedom.
        statistic = (abs(only_a - only_b) - 1) ** 2 / n
        p_value = math.erfc(math.sqrt(statistic / 2))
    return McNemar(only_a, only_b, both, neither, statistic=statistic, p_value=p_value)


def holm(p_values: dict[str, float], alpha: float = 0.05) -> dict[str, bool]:
    """Holm-Bonferroni: which hypotheses survive at a family-wide alpha.

    Per-domain member comparisons run into the dozens, so an uncorrected sweep
    would manufacture a winner in roughly one domain out of twenty by arithmetic
    alone.
    """
    ordered = sorted(p_values.items(), key=lambda kv: kv[1])
    m = len(ordered)
    rejected: dict[str, bool] = {}
    for index, (name, p) in enumerate(ordered):
        threshold = alpha / (m - index)
        if p <= threshold and all(rejected.get(prior, False) for prior, _ in ordered[:index]):
            rejected[name] = True
        else:
            rejected[name] = False
    return rejected

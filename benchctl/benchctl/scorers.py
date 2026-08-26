"""Scoring one answer, and deciding whether a layer may be admitted on the strength of many.

Two separable things live here on purpose. Scoring an item is per-family and mechanical. Deciding
admission is a statistical claim, and it is the part that has been getting designed wrong:

* An absolute lower confidence bound on the box's pass rate degenerates. At a true rate of 0.90 the
  one-sided 95% Wilson bound is about 0.81 at n=50 and 0.86 at n=200, so a floor of 0.85 needs two
  hundred items per family per length bin before anything is ever admitted. That is not caution, it is
  a design that cannot say yes.
* The comparison is paired. The same items go to the box and to the baseline, and only the items where
  they disagree carry information about the difference. Between close layers those are 10-20% of the
  set, so the difference is estimated far more tightly than either rate.
* The confidence level should follow the loss. A wrong admission is caught by the validator and the
  request falls back to an API, so what is lost is box time and some latency — bounded, and small.
  Demanding 95% against a bounded loss is how a project measures forever and ships nothing. One-sided
  80% is the default here, and it is a declared parameter rather than a hidden one.
"""

from __future__ import annotations

import math
import random
import re
from dataclasses import dataclass


@dataclass(frozen=True)
class Verdict:
    """One item, scored on one layer."""

    item_id: str
    passed: bool
    predicted: str | None
    expected: str | None
    detail: str = ""


@dataclass(frozen=True)
class PairedResult:
    """The comparison that admission actually rests on."""

    n: int
    box_passed: int
    baseline_passed: int
    only_baseline: int          # b: the baseline got it, the box did not
    only_box: int               # c: the box got it, the baseline did not
    difference_pp: float        # (box − baseline) in points
    lcb_pp: float               # one-sided lower bound on the difference
    confidence: float
    margin_pp: float
    mcnemar_p: float | None

    @property
    def non_inferior(self) -> bool:
        """Whether the box may go to shadow: the difference cannot be worse than the margin."""
        return self.lcb_pp >= -self.margin_pp

    @property
    def discordance(self) -> float:
        return (self.only_baseline + self.only_box) / self.n if self.n else 0.0


def exact_label(predicted: str | None, expected: str, *, allowed: tuple[str, ...]) -> Verdict:
    """An enum answer. Matched after normalisation, and only against labels that were offered.

    A model that answers with a label nobody asked for has not got it right by accident of parsing, so
    the allowed set is checked rather than assumed.
    """
    norm = (predicted or "").strip().lower()
    norm = re.sub(r"^[\s\-*`\"']+|[\s.。\-*`\"']+$", "", norm)
    matched = norm if norm in {a.lower() for a in allowed} else None
    return Verdict(
        item_id="",
        passed=matched is not None and matched == expected.strip().lower(),
        predicted=matched or (predicted or "").strip()[:80] or None,
        expected=expected,
        detail="" if matched else "answer is not one of the offered labels",
    )


def wilson_lower(passed: int, n: int, confidence: float = 0.95) -> float:
    """One-sided Wilson lower bound, for describing a single rate. Not used for admission."""
    if n == 0:
        return 0.0
    z = _z(confidence)
    p = passed / n
    denom = 1 + z * z / n
    centre = p + z * z / (2 * n)
    spread = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))
    return max(0.0, (centre - spread) / denom)


def _z(confidence: float) -> float:
    """Normal quantile for a one-sided bound. Table lookup, so no scipy in the harness image."""
    table = {0.50: 0.0, 0.80: 0.8416, 0.85: 1.0364, 0.90: 1.2816, 0.95: 1.6449, 0.975: 1.9600,
             0.99: 2.3263}
    if confidence in table:
        return table[confidence]
    nearest = min(table, key=lambda c: abs(c - confidence))
    return table[nearest]


def mcnemar_exact(b: int, c: int) -> float | None:
    """Two-sided exact test on the discordant pairs. Exact because the counts are small."""
    n = b + c
    if n == 0:
        return None
    k = min(b, c)
    tail = sum(math.comb(n, i) for i in range(k + 1)) / 2**n
    return min(1.0, 2 * tail)


def paired_non_inferiority(
    box: list[bool],
    baseline: list[bool],
    *,
    margin_pp: float,
    confidence: float = 0.80,
    draws: int = 20_000,
    seed: int = 20260827,
) -> PairedResult:
    """Is the box no more than `margin_pp` points worse than the baseline on the same items?

    The bound comes from a paired bootstrap over items rather than a closed form. Two reasons: the
    quantity is a difference of correlated proportions, where the closed forms disagree with each other
    at small n; and resampling items is the assumption that is actually true here — the items are a
    sample, the layers are not.
    """
    if len(box) != len(baseline):
        raise ValueError("paired comparison needs the same items on both layers")
    n = len(box)
    if n == 0:
        raise ValueError("no paired items")
    pairs = list(zip(box, baseline))
    b = sum(1 for x, y in pairs if y and not x)
    c = sum(1 for x, y in pairs if x and not y)
    diff = (sum(box) - sum(baseline)) / n * 100

    rng = random.Random(seed)
    diffs = []
    for _ in range(draws):
        sample = [pairs[rng.randrange(n)] for _ in range(n)]
        diffs.append((sum(1 for x, _ in sample if x) - sum(1 for _, y in sample if y)) / n * 100)
    diffs.sort()
    index = int((1 - confidence) * (draws - 1))
    return PairedResult(
        n=n,
        box_passed=sum(box),
        baseline_passed=sum(baseline),
        only_baseline=b,
        only_box=c,
        difference_pp=diff,
        lcb_pp=diffs[index],
        confidence=confidence,
        margin_pp=margin_pp,
        mcnemar_p=mcnemar_exact(b, c),
    )

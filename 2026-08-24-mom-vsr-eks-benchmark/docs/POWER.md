# Can v2 see what it is looking for?

The plan's first condition is that the design resolves a Δ of one to two utility points
before any money is spent. This is that computation, run on v1's own matrix
(`bench/power.py`), and the answer is a qualified no: **one point is out of reach at any
budget this project would spend, and two points is reachable only by asking each cell
more than once.**

Nothing here needed a new call. Everything below is a reading of the 12,569 answers v1
already paid for, plus its repeat pass.

## What decides the answer

Power for a paired comparison is set by **discordance** — the share of questions where
exactly one side is right — and not by either side's accuracy. Questions both sides get
right, however many, contribute nothing. Among the five strongest arms on the
calibration fold, discordance on the test fold runs:

| Pair | Discordant | Net |
| --- | --- | --- |
| gpt-5.6-sol / claude-sonnet-5 | 11.8% | +2.3% |
| grok-4.6 / claude-sonnet-5 | 11.5% | +4.3% |
| claude-opus-5 / claude-sonnet-5 | 11.1% | +7.1% |
| claude-fable-5 / claude-sonnet-5 | 10.7% | +6.6% |
| claude-fable-5 / gpt-5.6-sol | 8.9% | +4.3% |
| claude-opus-5 / grok-4.6 | 7.6% | +2.7% |
| claude-opus-5 / gpt-5.6-sol | 7.6% | +4.8% |
| claude-fable-5 / grok-4.6 | 7.5% | +2.3% |
| grok-4.6 / gpt-5.6-sol | 6.6% | +2.0% |
| claude-fable-5 / claude-opus-5 | 5.3% | −0.4% |

The two strongest arms are the least discordant pair in the table, at 5.3%. That is the
structural problem in one number: the arms a frontier would actually choose between
agree with each other more than any other pair in the pool, so the questions on which a
router could earn anything are the scarcest ones available.

## The closed-form screen

At 5% two-sided and 80% power, on the 693 complete test questions:

| Discordance | Detectable at n = 693 | n for Δ = 1 pt | n for Δ = 2 pt |
| --- | --- | --- | --- |
| 11.8% (most discordant strong pair) | 3.66 pt | 9,288 | 2,322 |
| 8.9% (median) | 3.18 pt | 7,023 | 1,756 |
| 5.3% (the two strongest) | 2.46 pt | 4,191 | 1,048 |

So the current fold resolves about two and a half to four points. The plan is looking
for one to two.

## Half the spread is the harness, not the models

The paired difference between the two strongest arms has a variance of 0.0535 on the
test fold. Splitting it against the measured re-ask disagreement rates (1.7% and 4.2%):

| Component | Variance |
| --- | --- |
| Re-asking the same cell | 0.0292 |
| The arms actually differing | 0.0243 |

**More than half of what looks like disagreement between the two best arms is the same
arm answering differently on a second ask.** That reframes the cheapest lever: asking
each cell three times removes two thirds of the larger component, and no amount of extra
questions touches it.

The simulation — questions resampled with replacement from the observed differences,
centred and shifted to the Δ being tested, studentised statistic, size verified at 5%
under the null:

| Utility | Asks per cell | Power at n = 693, Δ = 1 pt | n for 80% at Δ = 1 pt | Power at n = 693, Δ = 2 pt | n for 80% at Δ = 2 pt |
| --- | --- | --- | --- | --- | --- |
| accuracy (λ = 0) | 1 | 23% | ~4,200 | 64% | ~1,200 |
| accuracy (λ = 0) | 3 | 31% | ~2,700 | 81% | 693 |
| λ = 20 | 1 | 14% | ~6,200 | 45% | ~1,700 |
| λ = 20 | 3 | 19% | ~4,900 | 58% | ~1,200 |

The λ = 20 utility is harder than accuracy alone throughout, because the cost term adds
variance faster than it adds signal — the same heavy output-length tail that turned out
to be most of v1's λ effect.

## What that costs

Priced at v1's measured tokens per member, over the nineteen arms the pool now declares:

| Design | Calls | Cost (floor) |
| --- | --- | --- |
| 693 questions, 1 ask | 13,167 | ~$53 |
| 693 questions, 3 asks | 39,501 | ~$158 |
| 1,200 questions, 3 asks | 68,400 | ~$274 |
| 2,700 questions, 3 asks | 153,900 | ~$617 |

A floor, not an estimate: every arm is priced at its member's default-effort token usage,
and the point of the effort dial is that higher levels spend more. The real figure is
likely two to three times these for the reasoning arms.

## The verdict

**Chasing one point is not worth doing.** It needs 2,700 questions at three asks for
accuracy alone and about 4,900 for the λ = 20 utility — four to eight times v1's
spend before the selection variance the screen leaves out, and that variance only makes
it worse. If the honest expectation is a one-point Δ, the plan's own gate says stop.

**Two points is a real design.** 1,200 questions at three asks per cell clears 80% for
both the accuracy and the λ = 20 versions, at a few hundred dollars. That is what should
be pre-registered: a primary MDE of two points, with one point declared in advance as
unresolvable rather than reported as a null.

## What this cannot tell us

The screen is on the model axis. v1 holds no cell for a member at a non-default effort,
so the discordance between a member and *its own* higher level — the quantity v2 actually
turns on — is not in this data. It could be smaller than the between-model figures, in
which case even two points is out of reach, or larger, in which case the design gets
cheaper. The screen is also optimistic by construction: it compares two fixed arms,
while the estimand chooses both sides, so the real variance carries a selection term
this does not.

That leaves one measurement standing between the plan and a decision: a pilot on the
effort axis. To pin a discordance near 10% to within half its value takes about 140
questions per pair; to within a quarter, about 550. Three members declare effort levels
today, so a pilot of 150 questions across those members at every level is roughly 1,800
calls — tens of dollars — and it decides whether the 1,200 × 3 design is the right one,
too small, or pointless.

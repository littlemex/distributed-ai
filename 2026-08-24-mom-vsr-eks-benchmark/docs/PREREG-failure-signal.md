# Pre-registration: can an in-episode signal tell that the box failed?

**Written 2026-08-29, before looking at any separation.** Committed before the analysis runs, because
the analysis is a search over signals on 218 already-paid-for episodes and the difference between a
finding and a fishing expedition is whether the reading was fixed first.

## Why this question and not another

`docs/results-function-calling-arm.md` establishes that capability across the three tiers is a strict
nesting: everything the box solved, the cheap API solved; everything the cheap API solved, the
expensive one solved. Nesting has a hard consequence — **routing cannot raise quality, only lower cost** — and lowering cost then takes exactly one shape: try the cheap tier, escalate what it fails. Priced
from the per-instance bills, that arrangement saves 42.2% against the expensive API and 5.8% against
the cheap one.

Both of those figures assume an oracle. In the benchmark the box's failure is known because the
repository's own test suite judges the patch *after* the episode ends. In production there is no such
suite — that is why the task was given to a model. **So the 42.2% is the ceiling of a policy that
cannot currently be implemented, and what is realisable is whatever a failure detector recovers of
it.** This pre-registration fixes how that detector will be evaluated.

## The claim under test

> On episodes the box ran, at least one signal available *inside* the episode separates the episodes
> whose patch passed the hidden tests from those whose patch did not.

## Signals, named in advance

Enumerated from the recorded step schema, not from a first look at which ones separate. Every one of
these is available in production, i.e. computable without the hidden tests.

**Per-episode terminal state**

1. `stopped_because` — the agent said it was finished / step budget exhausted / token budget
   exhausted / unreachable.
2. `totals.steps` — how many steps it used.
3. `totals.diff_bytes` — whether it produced a patch at all, and how large.

**Per-episode aggregates over steps**

4. `tests_passed` — the outcome of tests the model chose to run itself, aggregated as: last non-null
   value; any `false`; all `true`. **Known limitation, stated in advance: this field is non-null on
   only 483 of 4,660 recorded steps (10.4%), because it is set only when the model called
   `run_tests`.** An episode may carry no value at all, and "no value" is itself a candidate signal.
5. `verify_failures` — how many of its own test runs came back failing.
6. Repeated-signature count — the loop detector's own material: how often the same action was
   repeated.
7. `format_compliance.no_action` + `unknown_tool` + `empty_required_arg` — how much of the episode was
   spent failing to drive the tools.
8. Step-type mix — the share of the episode spent on `patch` versus `read` / `search` / `verify`.
9. `thinking_chars` summed, for the arms where thinking is on.

**Explicitly excluded**, because they are not available in production or are the answer in disguise:
`score.json`, anything derived from the hidden test names, and the diff's content compared to the
reference patch.

## The reading, fixed now

**Population.** Episodes driven end to end by one tier (`self-hosted-always`, `cheap-always`,
`premium-always`), excluding episodes that ended on transport failure (`unreachable`, or the gateway's
200-with-empty-stream), because those say nothing about the model. The box's thinking-on and
thinking-off passes are separate populations and reported separately; they are not pooled.

**Primary reading.** For each signal, on the box's episodes: the two-by-two of signal against
solved, with Fisher's exact test, and the false-negative rate that matters operationally — the share
of *unsolved* episodes the signal would have let through as successes.

**Asymmetric costs, stated before seeing the numbers.** A false "the box succeeded" ships a wrong
answer. A false "the box failed" costs one escalation, i.e. the cheap or expensive tier's bill for
that instance, which is $0.166 and $0.679 on average here. The costs are not symmetric and the
threshold must not be chosen to maximise accuracy. **The operating point is fixed now: the detector
must catch at least 90% of unsolved episodes** (recall on failure ≥ 0.90), and among detectors that
clear that bar the one with the fewest false escalations wins.

**What counts as acting on it.** A signal is actionable only if, at that operating point, the
escalation arrangement priced in `results-function-calling-arm.md` still beats the fallback tier used
alone. That is the number to report — not the AUC, not the p-value. Concretely: recompute the
`box first, escalate on the detector` total against `fallback alone`, on the same twelve instances,
using the detector instead of the oracle. **If the saving goes to zero or negative, the detector is
not usable however good its statistics look.**

**Multiplicity.** Nine signal families are being tested. Bonferroni over nine at 0.05 gives 0.0056,
and that is the bar for calling a single signal significant. A signal that clears the operating point
but not the corrected threshold is reported as suggestive and as needing the 24-instance expansion,
not as a result.

**Sample size, acknowledged in advance.** The box has 15 thinking-off and 15 thinking-on episodes
under the function-calling protocol, of which 12 are paired. Six solved and nine unsolved in the
thinking-off pass. With n that small, no signal can clear Bonferroni unless the separation is nearly
perfect. **That is expected, and it is the point:** this analysis is cheap and its likely honest
outcome is "nothing separates at this n", which decides whether to spend on the 24-instance expansion
rather than pretending to answer now.

## The two outcomes and what each means

**Something separates.** The escalation policy becomes implementable, and its realisable saving —
recomputed with the detector in place of the oracle — replaces the 42.2% as the number the project
reports. The detector's false-negative rate becomes a quality claim that has to be stated wherever
the saving is.

**Nothing separates.** Then the honest statement is that on this signal set, at this sample size, the
box cannot be used as a first stage, and the 42.2% stays a ceiling rather than a plan. That is a
publishable result and it redirects the project: either to a signal set that does not exist yet
(which this project already refused to build once, see `benchctl/docs/decided-against-fabrication-verifier.md`),
or to committing a whole traffic family to one tier rather than routing per request.

## What this does not test

Whether difficulty can be predicted *before* the episode runs. That is a different policy — pick the
tier from the task, not from the attempt — and it needs a different pre-registration. It is worth
noting that this project already found, in v1, that an inferred difficulty label carried no accuracy
signal at p = 0.58, which is why the step-type label was derived from the action taken instead.

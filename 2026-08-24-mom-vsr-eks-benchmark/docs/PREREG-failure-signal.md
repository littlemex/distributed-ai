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

## Amended 2026-08-29, before looking, on two advisors' reading

Both advisors independently said the polarity was wrong, and they are right. Given the cost asymmetry
— a false "the box succeeded" ships a wrong patch, a false "the box failed" costs one escalation at
$0.166 or $0.679 — the object to build is not a failure detector but a **high-precision success
detector**: escalate by default, and keep the box's output only when a cheap sufficient condition for
success holds. That is a strictly easier thing to build, because a sufficient condition can be
conservative, and its natural candidate (the model's own test run passing on its own patch) has a
narrow failure mode rather than an open-ended one.

One premise in the first draft was also too strong. "In production there are no tests" is wrong for
coding traffic specifically: repositories have suites, linters and CI. The self-run `run_tests`
outcome is not a proxy for a production signal — for this traffic it *is* the production signal.

Three further amendments, all before any look:

- **Post-fix episodes only.** The 120 episodes from before the protocol fix were produced by a harness
  on which the box lost 42% of its actions, so their step counts, diff sizes and terminations describe
  a different failure mode. They are used for nothing here, not even as priors.
- **The signal list is closed to five, and only univariate decision stumps are allowed.** At n ≈ 12 per
  arm a fitted model is a random number generator. The five: (a) the final outcome of self-run tests on
  the model's own patch, (b) whether the episode hit the step ceiling, (c) whether any diff was
  produced, (d) step count, (e) diff size. Signals 6-9 of the original list are dropped rather than
  kept as extras, because keeping them is the fishing.
- **The lead hypothesis is named in advance:** *escalate iff (ceiling hit OR self-run tests failed or
  never ran)*, i.e. keep only an episode that ended on its own having run its own tests green. It is
  named now because the recorded data may well already support it, and a rule that is stated first is
  evidence where the same rule found afterwards is not.

**The metric is money, not AUC.** Report the realised cascade cost under the rule, bracketed by
always-escalate ($8.1484 to the expensive tier) and the oracle ($4.7128). The rule's value is where it
lands in that bracket. Report alongside it the keep-precision, P(judged solved | rule says keep).

**The bar to act, fixed now.** Keep-precision must be 1.0 on the twelve development instances; then
the rule is validated on the twelve instances not yet run (candidate 3), where at most one false keep
is permitted and at least half the oracle gap must be recovered. Anything weaker supports a shadow
run, not a routing change.

**And the sample bound is stated before any of it.** With zero observed false keeps, the one-sided 95%
upper bound on the accepted-error rate is about 5% at 59 accepted episodes, 3% at 100, 1.7% at 177.
So this data can find a promising rule or kill a bad one; it cannot certify a defect rate below 1%
whatever it shows. If an escaped defect costs $100 against an escalation at $0.679, the economically
justified keep threshold is P(success) > 99.3%, which no sample this size can demonstrate. The
deliverable is therefore a candidate rule and a shadow-mode recommendation, not a production switch.

## The claim under test

> On episodes the box ran, at least one signal available *inside* the episode identifies a subset of
> episodes whose patch passed the hidden tests, with no false members.

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

## The free calculation this pre-registration exists alongside

One advisor pointed out a number this project has not computed and should have: the **cheap → expensive
cascade, with no box at all**. Every escalation figure so far starts from the box. If routing the cheap
API's failures to the expensive one lands near the box → expensive oracle figure of $4.7128, then the
box is not merely hard to route to — it is redundant against an arrangement with no fixed cost, no
capacity planning and no ceiling to blow through.

That calculation needs no pre-registration because it involves no search: it is one sum over
per-instance bills already recorded. It is reported next to the detector result, and if it comes back
at or below the box cascade, it is the headline and the detector is a footnote.

## What this does not test

Whether difficulty can be predicted *before* the episode runs. That is a different policy — pick the
tier from the task, not from the attempt — and it needs a different pre-registration. It is worth
noting that this project already found, in v1, that an inferred difficulty label carried no accuracy
signal at p = 0.58, which is why the step-type label was derived from the action taken instead.

---

# Pre-registration addendum: raising the step ceiling

**Written 2026-08-29, after the free cross-tabulation below and before the run.**

## What the free check already settled

Both advisors asked for the censoring cross-tab before spending anything, and it resolves the thinking
confound without a run. On the twelve paired instances:

| | thinking off | thinking on |
|---|---|---|
| cut off (step or token ceiling) | 4 | 4 |
| ended on its own | 8 | 8 |
| solved among those that ended on their own | **5 / 8** | **5 / 8** |
| solved among those cut off | 1 / 4 | 0 / 4 |

Thinking-on is **not** more censored, and conditional on ending freely the two settings are identical.
The whole 6-versus-5 difference is one instance, `pylint-6386`, which both settings drove to the 40-step
ceiling — thinking-off produced a 765-byte patch that passed and thinking-on a 1,013-byte patch at 4.5×
the output tokens that did not. **So "thinking does not fit in forty steps" has no support, and
"thinking does not help on this corpus" stands.** The thinking question needs no further spend.

## What still needs the run, and what it would change

Four of twelve box episodes are right-censored, and only 1 of those 4 solved. If the ceiling is what
stops them, the box's 6/12 is an underestimate, and everything downstream moves: the nesting (a box
solve that the cheap tier missed would give the box a capability argument for the first time), the
oracle cascade at $4.7130, and the 6.8% margin over the no-box arrangement.

**The run.** All fifteen instances, box only, thinking off, `--max-steps 80` and the token budget raised
in proportion to 2.4M so the step ceiling stays the binding constraint rather than handing the episode
to the token ceiling instead. All fifteen rather than the censored four, because selecting the censored
ones conditions on a prior stochastic outcome and the comparison would be biased in the box's favour.
No gateway credit: the box is billed by the hour and is otherwise idle.

**Readings fixed now.**

1. **Solve count at 80 steps against 6/15 at 40.** Reported with the exact paired test over discordant
   instances, and with the count of episodes that still hit 80.
2. **Whether the nesting survives.** Specifically: does any instance appear that the box solves and
   `gpt-5.6-terra` does not? That is the one outcome that changes the project's recommendation from
   "do not self-host for this traffic" to "the box has a capability argument", and it is named now so
   that finding it later cannot be presented as a surprise.
3. **The economics, recomputed.** The oracle cascade and the margin over the no-box cascade, at the new
   solve count and the new bill. **The box's episodes get more expensive as the ceiling rises**, so a
   higher solve count does not automatically improve the margin, and both terms are reported.
4. **The budget asymmetry, stated.** The API arms ran at 40 steps and all of them ended on their own, so
   raising only the box's ceiling does not disadvantage them — but it does mean the arms no longer share
   a budget. Any comparison after this run is reported as "box at 80 steps against APIs at 40, where the
   APIs never reached 40", and the fact that no API episode was censored is what makes that admissible.

**What would not be admissible:** reporting the box's best ceiling against the APIs' as-measured
numbers without saying the ceilings differ, or raising the ceiling again if 80 also censors. If episodes
still hit 80, that is reported as "the box does not converge on this traffic", not as a reason for 160.

---

# Pre-registration addendum: the held-out nine

**Written 2026-08-30, before the run.** The first fifteen instances were selected by a rule stated in
advance; these are the nine the rule left out of the twenty-four in `pilot-subset.json`, so the held-out
set is defined by the original selection and not chosen now.

`astropy-14995`, `django-17084`, `matplotlib-26342`, `requests-2931`, `xarray-4695`, `xarray-6992`,
`pylint-7277`, `pytest-8399`, `scikit-learn-15100`.

Three arms, the same configurations already fixed: box at 40 steps thinking off (the setting that
converges and scores best), `gpt-5.6-terra` on the Responses wire at reasoning `high`, `claude-fable-5`
on chat completions. Function calling throughout.

## The primary reading, and it is not the confidence interval

**Does the nesting break?** Specifically: is there an instance the box solves that `gpt-5.6-terra` does
not? Twenty-four instances with zero such cases bounds the true rate at roughly 12% by the same
three-over-n rule the earlier 2-layer nesting used; one such case turns the box's argument from cost to
capability and reopens `results-escalation-and-the-box.md`. **This is stated as the primary reading
because the project's recommendation currently rests on the nesting, and an expansion run for confidence
intervals that happened to find a counterexample would be indistinguishable from one that went looking
for it.**

Secondary, in order: the same reading against `claude-fable-5`; the three-arm solve counts with exact
paired tests on the pooled twenty-four; and the arrangement prices recomputed on the pooled set,
including the cheap → expensive cascade with no box.

## The detector's held-out test, and what it can still learn

The pre-registered detector failed on the development twelve — best keep-precision 0.62 against a
required 1.0 — so there is no surviving rule to validate. What the nine can still do is test whether
that failure replicates, and the reading is fixed now: **the two best development rules ("did not hit
the ceiling", and the named lead hypothesis) are applied unchanged to the nine, and their keep-precision
is reported whatever it is.** A rule that reached 1.0 here after 0.62 there would be sampling noise, not
a discovery, and would be reported as such.

## The token budget, and why it is stated

The gateway's personal credit is denominated in tokens and meters at roughly 1.75× the tokens this
harness records, measured across the runs so far. Nine episodes on the two API tiers record about 4.3M,
so about 7.5M of credit is needed; the allowance was reset to 12M before the run so that exhaustion
mid-pass cannot silently truncate an arm and leave a partial comparison on disk. **If an arm does die on
credit, its instances are re-run rather than reported partial**, because a subset of nine chosen by where
the money ran out is not a subset chosen by a rule.

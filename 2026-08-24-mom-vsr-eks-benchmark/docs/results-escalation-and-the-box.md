# The escalation policy the nesting implies, priced — and why the box does not survive it

**Measured 2026-08-29, no new spend.** Every figure below is a sum over per-instance bills already
recorded by `results-function-calling-arm.md`. The detector analysis follows
`PREREG-failure-signal.md`, written and committed before any separation was looked at.

## The question

Capability across the three tiers is a strict nesting, so routing cannot raise quality and the only
saving takes one shape: attempt a cheap tier, escalate what it fails. Pricing that arrangement needs an
answer to "did it fail", which in the benchmark comes from a test suite that production does not have.
Two things therefore had to be measured: what the arrangement is worth with a perfect answer, and what
a real answer recovers of it.

## Arrangements, priced with a perfect failure signal

Twelve instances, oracle stopping at every stage so the comparison is of arrangements and not of
detectors.

| arrangement | solved | total | per solved task | stage attempts |
|---|---|---|---|---|
| expensive alone | 12/12 | $8.1485 | $0.6790 | 12 |
| cheap alone | 8/12 | $1.9911 | $0.2489 | 12 |
| box alone | 6/12 | $0.5714 | $0.0952 | 12 |
| **cheap → expensive, no box at all** | 12/12 | **$5.0326** | $0.4194 | 12 + 4 |
| box → expensive | 12/12 | **$4.7130** | $0.3927 | 12 + 6 |
| box → cheap | 8/12 | $1.8764 | $0.2345 | 12 + 6 |
| box → cheap → expensive | 12/12 | $4.9178 | $0.4098 | 12 + 6 + 4 |

**The arrangement with no machine in it costs $5.0326 and the best arrangement with the box costs
$4.7130.** The box's entire contribution, with a perfect oracle telling it when to give up, is
**$0.3196 across twelve tasks — 2.7 cents a task, 6.8%.** Adding it as a third stage in front of the
API cascade is *worse* than using it as the only first stage, and beats the no-box cascade by 2.3%.

## What that says about owning the machine

The box bills $15.2174 an hour whether or not it is used. At 2.7 cents of oracle saving per task it has
to process **571 tasks an hour** to cover its own bill against an arrangement that needs no machine.

Measured on this corpus, a box episode takes a median of 76 seconds and a mean of 105. So:

| episodes in flight | tasks an hour at 105s each |
|---|---|
| 4 | 137 |
| 16 | 547 |
| 48 | 1,642 |

Break-even sits between 4 and 16 concurrent episodes — that is, **the box must run at close to
saturation, continuously, on exactly this kind of traffic, to be worth owning at all**, and that is
before any detector loses part of the 6.8%. Against the cheap tier alone the requirement is 1,592 tasks
an hour, because the oracle saving there is 0.96 cents a task.

This is consistent with `benchctl/docs/results-arrival-sweep.md`, which put the crossover at roughly
3,295 prefix-reusing requests an hour on a different traffic shape. Both say the same thing in
different units: the box is a volume instrument, and pilot volume is not volume.

## The detector, per the pre-registration

Twelve post-fix box episodes, thinking off, six solved. Five signals, univariate stumps, the lead
hypothesis named in advance. The bar was **keep-precision 1.0** — a rule may only keep episodes it is
sure about, because a false keep ships a wrong patch while a false escalation costs $0.679.

| rule | kept | of which solved | **false keeps** | keep-precision |
|---|---|---|---|---|
| LEAD: ended on its own **and** own tests green | 7 | 4 | **3** | 0.57 |
| did not hit the step ceiling | 8 | 5 | **3** | 0.62 |
| own tests green whenever they ran | 10 | 4 | **6** | 0.40 |
| produced a diff at all | 11 | 6 | **5** | 0.55 |
| used fewer than 30 steps | 4 | 2 | **2** | 0.50 |
| diff larger than 500 bytes | 7 | 3 | **4** | 0.43 |

**Every rule has false keeps, and the best keep-precision is 0.62 against a required 1.0.** Nothing
clears the bar; nothing comes close. No rule reaches the corrected significance threshold either — the
best p is 0.545, uncorrected.

### A metric error of mine, corrected here

The first version of this analysis reported "share of the oracle gap recovered" for each rule, and some
rules scored over 100%. That number is meaningless whenever the rule changes how many tasks get solved:
a rule that keeps a broken patch is cheaper *because it ships a wrong answer*, and calling that recovery
is exactly the confusion the pre-registration was written to prevent. **The bill may only be compared at
equal quality.** At equal quality — 12 of 12 solved — the only arrangements available are
always-escalate at $8.1485 and the oracle at $4.7130, and no rule here reaches the second while staying
at the first's quality. The best rule, "did not hit the ceiling", bills $5.0431 and solves 9 of 12: it
buys $3.10 by dropping three solves, which is a quality regression wearing a discount's clothes.

### And the natural signal is structurally inverted, not merely weak

The model ran its own tests in all twelve episodes, so the signal is available. It points the wrong way:

| the model's own tests at the end | episodes | actually solved |
|---|---|---|
| green | 10 | 4 (40%) |
| red | 2 | **2 (100%)** |

Base rate is 6 of 12. Two red episodes is far too few for a statistical claim, but the direction has a
structural cause that does not depend on sample size: **SWE-bench's judging tests are `fail_to_pass`
tests, which by construction are not in the checkout.** A green run of the tests that *are* present
means "I did not break anything", never "I fixed the reported bug". A model that stops when its own
tests are green has stopped one step before the work it was asked to do, and that is what four of these
episodes did.

This is worth stating plainly because one advisor's reasoning for running this analysis first was that
in-repo tests are not a proxy for a production signal but *are* the production signal. For coding
traffic in general that is right. For this benchmark shape it is structurally false, and any
verification signal for this corpus has to come from somewhere other than the tests in the tree.

## What follows

1. **For this traffic, on this evidence, do not self-host.** The API cascade — cheap first, escalate
   its failures to the expensive tier — solves 12 of 12 for $5.0326 with no machine, no capacity
   planning, and no step ceiling to blow through. The best the box can do with a perfect oracle is
   6.8% better than that, and it cannot be given a perfect oracle.
2. **The escalation signal is the blocker, not the model.** The box's failures are not detectable from
   inside its own episode with anything recorded here, and the most natural candidate is inverted for
   structural reasons. Any future attempt has to bring a signal from outside the checkout.
3. **Turn thinking off on this box for this traffic**, at this budget. That decision is clean
   regardless of everything above: it costs 1.90× and solves one fewer.
4. **What would change the recommendation**, stated so it can be tested rather than argued: sustained
   volume above roughly 550 tasks an hour on prefix-reusing traffic; a verification signal from outside
   the repository's own tests; a traffic family where the box's solve set is *not* a subset (which would
   give it a capability argument rather than a cost one); or a requirement — data residency, latency,
   air-gap — that the APIs cannot meet at any price.

## What this does not say

**That the box is a bad model.** It solves half of these instances at a sixth of the expensive tier's
per-task price. The finding is about an arrangement, not a ranking.

**That the nesting is proven.** Twelve instances, and only the box-versus-expensive gap clears p < 0.05.
If the nesting breaks even once on a larger set — the box solving something the cheap tier misses — the
box gains a capability argument and this page's conclusion has to be reopened. That is a reason to run
the remaining twelve instances, and it is a test of the nesting rather than a tightening of intervals.

**That the API cascade is free of the same problem.** It also needs to know when the cheap tier failed.
The $5.0326 is an oracle figure too. What makes it the recommendation anyway is that it has no fixed
cost: a wrong escalation decision there wastes one API call, while the box's version wastes a call *and*
an hour of a machine that was rented regardless.

**Anything about latency.** Box-first escalation puts a median 76 seconds of box time in front of the
API attempt. For interactive traffic that may be disqualifying independently of cost, and nothing here
measures it.

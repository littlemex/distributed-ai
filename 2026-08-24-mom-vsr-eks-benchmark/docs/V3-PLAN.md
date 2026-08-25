# v3 — how cheaply can a premium model be replaced, and where must it be kept

v1 asked whether routing between models beats the best single model on MMLU-Pro. It does
not. v2 asked whether the compute dial explains that. On MMLU-Pro the dial has one notch
and nine of twelve arms are dominated, so there was nothing left to explain. Both answers
are negative and both are about a benchmark whose answer is a letter of the alphabet.

v3 inverts the question to the one the requirement actually contains. The baseline is no
longer the best single model to be beaten; it is **the premium model used for everything**,
which is what an operator pays today. The target is not accuracy but **cost and latency at
no loss of quality**. Under that framing Δ ≈ 0 is the success case: same work done, most of
the bill gone.

## The decision, and what decided it

Put to two independent reviewers with the measured results attached. The design below is
the recommendation that survived, with the arithmetic in `SWITCH-ECONOMICS.md` deciding the
shape of the policy.

**Venue: a stratified subset of SWE-bench Verified, 200–250 instances.** Chosen for the
hardness of its scorer above everything else, because v1's largest lesson was that more
than half the variance in a paired comparison was the harness rather than the models.
Unit tests are deterministic; an LLM judge or a simulated user is a noise source and a
billed one. `terminal-bench` has roughly 90 tasks, below the sample size the power
calculation needs. τ-bench's user simulator reintroduces exactly the noise v1 spent its
budget removing. SWE-bench also has the trigger built into the environment — tests fail —
and a published premium-to-cheap gap of 20–30 points, so the non-inferiority claim is not
vacuous. Its structure matches the requirement too: searching, reproducing and reading
tests is replaceable labour, while designing the patch is the step worth paying for.

One branch has to be pre-registered here: if the pilot finds the premium and cheap arms
within three points of each other on single-run success, the non-inferiority claim is
vacuous before it starts — there is no quality to preserve. The response is to restrict to
a harder stratum, or to change the outcome from success to effort-to-success, and not to
report a comfortable null.

**Estimand: the reduction in cost per solved task, subject to non-inferior success.** Not
success at matched cost. The requirement is "do not lose quality, spend less", so quality
is the constraint and spend is the objective; reversing them answers a different question.
The unit is **cost per *solved* task**, which is the only unit that charges a cheap model
for taking more turns, and charges a failed episode's tokens to whatever policy failed.

**The margin and the sample size are the same decision, and the wording has to follow it.**
One-sided at 5% with 80% power needs `n ≈ 6.18 · d / Δ²` paired tasks:

| Discordance d | 3-point margin | 5-point margin |
| --- | --- | --- |
| 0.05 | 343 | 124 |
| 0.10 | 687 | 247 |
| 0.15 | 1,030 | 371 |

So 200–250 tasks buys a **5-point** margin, not a 3-point one. A 5-point margin at 250
tasks permits twelve or thirteen extra failures, which is not "no loss of quality" — the
second reviewer was right to object to the phrasing, and the fix is the phrasing, not the
number. **The first run claims "at most five points of success rate given up, for X% less
money", and nothing stronger.** If it comes back with the difference near zero, the
pre-registered follow-up is roughly 690 tasks at the same design, which converts the same
result into a 3-point claim for about 2.8 times the spend. Deciding that ladder in advance
is what stops the margin from being chosen after seeing the answer.

**Triggers, three, all computable from logs with no extra model call:**

1. the verifier disagreeing — a reproduction or regression test failing;
2. the same file or command being retried k times, which is loop detection;
3. a step or token budget being exceeded, as a deterministic backstop.

Self-reported confidence is excluded: v1 showed a plausible-looking feature (the domain
label) carrying no accuracy signal at p = 0.58, and a model's own confidence has no
calibration evidence here while adding prompt-dependent freedom to the experiment.
Disagreement between two cheap models is excluded on cost — it stands up a second full
context every time it is evaluated, and v1 measured the errors of strong arms as highly
correlated, so it would rarely fire and would agree when wrong.

**Escalation is one-way.** This is not a preference. `SWITCH-ECONOMICS.md` shows the switch
tax is paid on every switch, that one escalation in a 60-step session saves 63% while eight
spot escalations cost 33% *more* than never leaving the premium model. Round trips are
unaffordable, so the policy escalates once and stays.

**Cost model: measured, not modelled.** The billed tokens — cached and fresh distinguished
— go straight into cost per solved task. The switch tax is also reported on its own as a
diagnostic, because it is the term that decides whether the strategy can work at all.

## Two more policies, and the distinction that makes them work

Escalating the main thread is one mechanism. Two others were proposed after the desk
calculation, and they are not variations of it — they avoid the switch tax entirely, for a
reason worth stating plainly.

**The tax is charged for handing over the conversation, not for using a cheap model.** A
side task issued with its own small context — find the file that defines this symbol,
summarise this diff, read this test and say what it asserts — carries none of the
accumulated prefix, so there is nothing to re-establish. It can therefore happen as often
as the work calls for it, which is the opposite of the one-way constraint that governs the
main thread. Two mechanisms, two economics.

**Arm C: fill the capacity that is already paid for.** The self-hosted vLLM runs on a
g6e.12xlarge at $15.2174 an hour whether or not a request arrives, so its marginal cost up
to its throughput ceiling is zero and its true price is the hourly rate divided by what it
actually serves. That makes utilisation the price: this policy changes its own cost, which
is why v1's three readings for a self-hosted member — average realised, marginal
spare-capacity, saturated replacement — stop being an appendix and become the main table.

The policy is admission control: route to the self-hosted model while its in-flight count
is below a measured ceiling times a safety factor, and spill to a paid API above it. The
ceiling has to be measured first, and v1 shows why it is not a detail. At
`--max-num-seqs=2` the self-hosted arm measured 220 output tokens a second and a blended
$8.80 per million — 44 times the operator rate it was assumed to have, and dominated on
both axes. That was a serving configuration, not a model: the same box at a real batch
depth is an order of magnitude cheaper per token. So the sweep decides whether this arm
exists at all.

It also has a quality floor to clear, and on MMLU-Pro it did not: the self-hosted member
scored 0.652 against 0.832 for the best arm, eighteen points down. Which is exactly why the
next policy matters.

**Arm D: route by what the step is for, not by how hard it looks.** v1 killed *inferred*
difficulty — the domain label carried no accuracy signal at p = 0.58 — but an agent harness
does not have to infer anything. It knows what each step is for: searching, reading tests,
summarising, drafting, producing the final patch. The step type is a label we control rather
than one we predict, and it is causally connected to the capability the step needs. So the
policy is a pre-registered table from step type to tier, with drafting and searching on the
self-hosted or cheap tier and the decisive steps on the premium one.

The two compose: role-based routing produces exactly the stream of small, self-contained
side calls that capacity-first routing wants to fill a paid-for GPU with, and neither pays
the switch tax. If they work, they also answer the original requirement more directly than
escalation does — the expensive model is kept for the steps that decide the outcome, and
the cheap capacity absorbs the volume.

### What they add to the pilot

1. **The self-hosted throughput ceiling.** Sweep `max-num-seqs` over {2, 8, 16, 32} and
   concurrency past saturation; take the knee where p95 latency crosses the tier's SLO;
   apply a safety factor; report the effective price at that operating point from the
   hourly rate. The existing `gateway-concurrency` sweep is the tool.
2. **Per-step-type quality, by ablation.** Downgrade one step type at a time and measure the
   change in episode success. This is the only honest way to attribute quality to a step
   type, and at pilot scale it is a screen rather than an estimate.
3. **The share of a session that is side work** — steps and tokens — from our own traces and
   the AgentX ones. It bounds what capacity-first and role-based routing can save before
   either is implemented.

## Power, and what the pilot has to establish

Paired over tasks, McNemar structure, so the sample size is set by the discordance rate d
(the share of tasks exactly one policy solves), not by either policy's success rate. The
table under the estimand is the whole calculation; the pilot's job is to supply d.

A 20–30 episode pilot, before anything larger, measures four things:

1. **Whether the cache discount is real end to end** — that each provider reports cached
   input and the gateway passes it through. Everything in `SWITCH-ECONOMICS.md` rests on
   it, and if it is absent the baseline is far more expensive and the strategy looks
   better than analysed.
2. **Cost per episode per arm**, which sets whether 250 tasks fits the budget at all.
3. **The discordance rate d between the premium and cheap policies**, which sets n.
4. **Re-run flip rate on the same task and arm**, and the trigger firing rate with the
   context length at first firing. The first says whether adding tasks or re-running tasks
   buys power more cheaply — the agentic version of v1's finding that half the variance was
   re-asking. The second puts real numbers in the switch-tax inequality.

Pre-registered branches: if d > 0.25 and the flip rate is also high, a 5-point margin at
this budget is out of reach, and the choice is to widen the margin to 8 points or to stop.
Quietly reducing n is not one of the options. If a premium episode costs more than about
$1.50, 250 tasks does not fit and the fallback is `terminal-bench` with re-runs
substituting for its smaller task pool.

## The strongest argument against running it

Most of what a decision needs can be computed without an experiment, and half of it now
has been: with cache pricing, context-length distributions from the AgentX traces and the
rate table, the break-even between switch tax and cheap-step savings is a desk calculation.
Had that calculation come back empty — premium always cheapest — the experiment would have
been a costly way to buy a null that arithmetic already implied.

It did not come back empty. It came back saying cost prefers escalating as late as
possible while quality prefers escalating sooner, which makes the answer depend on exactly
one unmeasured quantity: **how well a trigger identifies the step where cheap work stops
being good enough**. That is what v3 buys.

It is also the part with the weakest external validity, because how a trigger performs
depends on how the scaffold searches, when it runs tests, and whether it compacts. Both
reviewers landed on that as the strongest objection, and the second one proposed the
answer: **two scaffolds over the same subset with the same policy and budget, reported
separately rather than pooled.** One lightweight agent loop and one of a different design;
if the direction of the result agrees across them, the claim is about one-way escalation on
long-horizon code work rather than about one harness's habits. That is a better use of the
same money than a single scaffold at larger n, and it is the design v3 adopts — with the
caveat that if the goal ever narrows to a go/no-go for one internal harness, external
validity stops being worth paying for and a single scaffold is correct.

## What carries over unchanged

The harness collects this already: per-call tokens split by cache state, TTFT and visible
decode rate on a streaming path, per-arm retirement, a spend ceiling that refuses to start,
a resume guard that will not mix two settings in one file, and the arm as the unit of
comparison. The three preconditions from v2 still apply — power before spending, routing
cost in dollars, a temporal held-out — and the second one is now cheap, because the routing
cost in this design is the switch tax and it is measured rather than estimated.

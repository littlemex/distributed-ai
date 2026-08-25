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

**Estimand: the reduction in cost per solved task, subject to non-inferior success.** Not
success at matched cost. The requirement is "do not lose quality, spend less", so quality
is the constraint and spend is the objective; reversing them answers a different question.
Non-inferiority margin **5 points of success rate, one-sided, paired by task**. Wider than
one would like, and set by what the budget can resolve rather than by taste — v1's
measurements put the detectable difference at a few points for several hundred paired
units, so a 2-point margin cannot be tested here and a 10-point one would make "no loss of
quality" meaningless. The unit is **cost per *solved* task**, which is the only unit that
charges a cheap model for taking more turns, and charges a failed episode's tokens to
whatever policy failed.

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

## Power, and what the pilot has to establish

Paired over tasks, McNemar structure, so the sample size is set by the discordance rate d
(the share of tasks exactly one policy solves), not by either policy's success rate:
n ≈ (z_α + z_β)² · d / Δ². At a 5-point margin and 80% power, d = 0.10 needs about 250
tasks and d = 0.15 about 370.

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
being good enough**. That is what v3 buys, and it is also the part with the weakest
external validity, since it depends on the scaffold. Both facts should be in the write-up
from the start.

## What carries over unchanged

The harness collects this already: per-call tokens split by cache state, TTFT and visible
decode rate on a streaming path, per-arm retirement, a spend ceiling that refuses to start,
a resume guard that will not mix two settings in one file, and the arm as the unit of
comparison. The three preconditions from v2 still apply — power before spending, routing
cost in dollars, a temporal held-out — and the second one is now cheap, because the routing
cost in this design is the switch tax and it is measured rather than estimated.

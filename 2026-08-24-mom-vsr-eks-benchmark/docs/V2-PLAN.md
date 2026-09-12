# v2 — the question worth asking next

v1 answered "does routing between models improve accuracy on MMLU-Pro". No. This
document is the plan for the question that survives that answer, written after three
rounds of adversarial review with two independent reviewers, and after four
computations that changed it.

The short version: **v2 is worth doing only if it answers "is model diversity
necessary, or is it a restatement of the compute dial?"** Everything else in the
obvious v2 backlog is engineering hygiene that cannot change a conclusion.

## What v1 established, in final form

| Finding | Status |
| --- | --- |
| Routing does not buy accuracy: VSR was 3.6 pt below the best single member | held |
| The 40% saving came from choosing a better single model, not from routing | held |
| VSR's selector cannot express per-domain quality, and sent 96% to one member | held |
| The domain label carries no accuracy signal (shuffle test, p = 0.58) | held **at λ = 0 only** |
| The domain label carries cost-side signal (p < 0.001 from λ = 20) | new |
| A cross-fitted per-domain policy clears the correct supporting line | **no, at any λ** |
| The self-hosted member is the cheap option | withdrawn — 44x mispriced, dominated |
| Two members reach most of the ten-member ceiling | suspect — selection-biased |

### The four computations that changed the plan

**1. The blade must be a utility, not accuracy.** A feature that predicts *difficulty*
rather than *which arm wins* cannot move an accuracy ceiling — every bucket still
prefers the strongest arm — while being exactly what cost-aware routing lives on. Re-run
on `accuracy − λ·cost`, the domain label goes from p = 0.58 at λ = 0 to p < 0.001 at
λ ≥ 20. v1's "no exploitable signal" was true only for the objective v1 happened to
score.

**2. Where that signal comes from decides whether MoM is needed at all.** Holding each
arm's cost at its own mean isolates the accuracy-side signal; holding accuracy at its
mean isolates the cost side:

| λ | Total gain | Accuracy-side | Cost-side |
| --- | --- | --- | --- |
| 20 | +0.0160 | +0.0097 (p = 0.006) | +0.0058 (p < 0.001) |
| 50 | +0.0217 | +0.0079 (p = 0.020) | +0.0092 (p < 0.001) |
| 100 | +0.0250 | −0.0003 (p = 0.20) | +0.0147 (p < 0.001) |

At λ = 100 the gain is **entirely token-length arbitrage** — mean output runs 541 tokens
in engineering against 101 in health, a five-fold spread that any feature can predict —
and arbitrage on output length needs no second model, only a compute dial. At λ = 20–50
a genuine accuracy-side component survives. That component, worth about one utility
point, is the whole case for model diversity.

**3. Hindsight signal is not learnable signal.** Fitting the λ-optimal per-domain
assignment on calibration and evaluating on test, against the correct supporting line
(the best single arm *on the scored fold*):

| λ | Policy | Best single arm | Difference |
| --- | --- | --- | --- |
| 5 | 0.8620 | 0.8841 | −0.0221 CI[−0.0397, −0.0034] |
| 20 | 0.8125 | 0.8162 | −0.0037 CI[−0.0207, +0.0132] |
| 50 | 0.7356 | 0.7189 | +0.0167 CI[−0.0100, +0.0449] |
| 200 | 0.4060 | 0.3734 | +0.0325 CI[+0.0000, +0.0644] |

Nothing clears it. An earlier version of this table compared against the arm chosen on
*calibration* and showed a significant win at λ = 50; that was an artefact of a weaker
baseline. Both sides have to be cross-fitted, and neither the cross-fitted nor the
test-selected baseline is right on its own — the first is too weak, the second carries
max-selection bias that flatters it.

**4. Under a linear utility, beating the mixture hull and beating the best single arm
are the same test.** The hull's optimum of `accuracy − λ·cost` is attained at a vertex,
so a policy whose utility exceeds every arm's utility lies strictly above the hull. The
hull machinery of v1 was the right instinct; the utility form is cleaner and strictly
stronger, and it is what v2 should report.

## The primary estimand

One number, pre-registered, cross-fitted on both sides:

```
Δ = frontier(all base models × effort levels) − frontier(best single base model × effort levels)
```

measured at matched cost, per latency SLO tier. Δ answers "is model diversity
necessary". **Δ ≈ 0 is an acceptable and useful result**: it would say the value is in
adaptive compute allocation within one model, which is dramatically simpler to operate.
Designing so that outcome is publishable is the best available defence against the
overfitting that killed v1's per-domain arm.

The λ-utility contests are secondary, and the accuracy/cost decomposition above must
accompany every one of them — otherwise a token-length arbitrage will be reported as
model complementarity.

## Three conditions. Without all three, do not run v2

1. **Power for a small Δ.** Computed — `docs/POWER.md`, from v1's matrix, no new calls.
   The condition is **half met, and it settles the target**: one utility point needs
   2,700 questions at three asks per cell for accuracy alone and about 4,900 for the
   λ = 20 utility, which is four to eight times v1's spend before the selection variance
   the screen leaves out, so one point is not worth chasing. Two points clears 80% at
   1,200 questions and three asks, for a few hundred dollars. Two findings changed the
   design rather than merely sizing it: the two strongest arms are the *least* discordant
   pair in the pool at 5.3%, so the questions a router could earn on are the scarcest
   available; and more than half the apparent disagreement between them is the same arm
   answering differently on a second ask, which makes asking each cell three times the
   cheapest lever and one that no number of extra questions substitutes for. What remains
   is the effort-axis pilot the screen cannot replace, about 1,800 calls. **Run —
   `docs/PILOT.md`.** It confirms the sizing and removes the reason to spend it here:
   above the lowest effort level the dial is indistinguishable from re-asking the same
   arm, the one real notch is off-to-on, and nine of twelve arms are dominated. See "The
   decision after the pilot" below.
2. **Routing cost in dollars.** The primary claim is "routable gain exceeds routing
   cost", and the right-hand side is currently blank. Feature computation, router
   inference, the added latency, and maintenance all have to be priced, or the inequality
   cannot be evaluated. v1 measured the latency term: +12.8 seconds per request.
3. **A temporal held-out.** Tariffs and model aliases move monthly — the cheapest member
   already changed once inside this project. Without a time-split evaluation the
   conclusion is "the answer for this pool in one week of 2026-08".

## Protocol, with the review's corrections applied

**Arms.** `model_config = base model × reasoning_effort`. Both reviewers converged on
this and on the renaming that follows: the object under study is
Mixture-of-Model-**Configs**, or adaptive compute allocation. Effort is an ordered scale
*within* a provider and not comparable across them — GPT's `low` and Grok's `minimal`
share no unit — so it enters as a per-model dose-response curve with a monotonicity
prior, not as independent cells.

**The blade, in three stages that are actually distinguishable.** The five-stage version
of this plan collapsed: a "feature-conditioned ceiling" evaluated by cross-fitting *is* a
learned policy, so its difference from the "learnable policy ceiling" measured
regularisation and sample size rather than learnability. The three surviving stages:

1. **Hindsight ceiling** — best arm per bucket on the scored fold, no cross-fitting,
   against a permutation null. Upward biased by construction; the null is biased the same
   way, so the test is valid while the effect size is not.
2. **Cross-fitted policy value** — a pre-registered policy class fitted on one fold,
   evaluated on another, against a cross-fitted baseline. This is the only number that
   estimates what a router could actually deliver.
3. **The live router** — with an offline paired replay in between, or the difference
   between (3) and (2) mixes implementation loss with online distribution shift.

**Permutation nulls.** Discrete features shuffle within stratum. Continuous features
(embeddings) permute rows across questions, which preserves marginals and the distance
structure while breaking the pairing — but conditioning on an exact embedding match makes
every question a singleton and the ceiling approaches memorisation, so the conditional
value is only defined relative to a pre-registered policy class, and the finding must be
reported as "this class could not extract signal". Measure the embedding's *incremental*
value over `task_type` by permuting within `task_type`, or "the embedding works" may be
rediscovering the label.

**Multiplicity.** One primary λ, pre-registered, or a simultaneous band over the grid.
v1's B-1 reported two of four λ significant, which is exactly the selective reporting the
correction is for. At high λ the heavy tail of token cost dominates the utility, so a
handful of expensive questions can drive p < 0.001 — influence diagnostics and a
winsorised sensitivity pass are required.

**Budget pruning must not pre-empt the hypothesis.** Screening out arms that are
dominated *on average* removes exactly the per-problem complementarity the experiment is
looking for, and screening at λ ≈ 0 eliminates the cheap arms that carry the cost-side
signal. Racing survives per λ: an arm lives if it is near the frontier at *any*
pre-registered λ. Never prune using data that is then reused for evaluation.

**Latency.** Stratify by SLO tier, then a 2D cost-accuracy frontier inside each tier;
never a 3D Pareto. Report `E2E`, `TTFT` (first *visible* token), `visible TPOT`, output
tokens, hidden thinking tokens where disclosed, and billed tokens as separate columns.
Do not call `E2E / output tokens` a TPOT — it mixes queue, prefill and thinking into a
decode rate. For reasoning arms TTFT absorbs the thinking, so the tiering metric differs
by use case: interactive tiers on time-to-first-visible-token, batch tiers on E2E only.
Block measurement by time of day; provider latency is non-stationary.

**Cost.** The router receives a pre-registered fixed tariff table; dynamic pricing makes
a run unreproducible and creates a feedback loop (route there because it is cheap, which
changes what is cheap). Self-hosted members are reported three ways — average realised,
marginal spare-capacity, and saturated replacement — with saturated replacement as the
headline and the others in an appendix. The replacement cost is measured from a load
sweep (`max-num-seqs ∈ {2, 4, 8, 16}`, same quantisation and parallelism, all results
including OOM reported), and the number used is the best cost *that meets the SLO tier* —
which is what makes "we tuned it to look cheap" a non-question: the tier picks the
setting.

## Decisions taken

**The self-hosted member stays out of the gateway.** The gateway already implements the
path — `served_by: "vllm"` with an `endpoint_key` allowlist and `HYBRID_SERVING_ENABLED`
— so this is configuration, not code. But the gateway runs on ECS in **us-east-1** and
the vLLM runs in EKS in **ap-northeast-1**, and `VLLM_ENDPOINTS` expects an in-VPC URL.
The options were: stand up a second vLLM in us-east-1 ($15/hour to re-measure an arm
already rejected), cross-region PrivateLink (injecting 75–150 ms one way into the path
whose latency we are measuring), a second gateway (a new regional confound), or leave it
direct. Both reviewers independently chose the last, and so does this plan.

**The "serving-path value" term is dropped, not deferred.** With one self-hosted model it
is perfectly confounded with that model's quality; reporting direct-path numbers beside
the others would present something unidentified as identified.

**"The self-hosted member is rejected" is narrowed.** Comparing our replacement cost
against a vendor's *sale* price is a category mismatch — the sale price may be subsidised
or strategic. The claim is: rejected as a consumer, at this configuration, this model and
this tariff.

**The pool is not shrunk yet.** The greedy arm-set curve is computed with one sample per
cell on the scored fold, so both the ordering and the "two members are enough" reading
carry selection bias and variance that are not separated. And if the cost-side signal
comes from the cheap arms among the members a shrink would remove, shrinking deletes the
finding. Decompose the λ gain by contributing arm first.

**Benchmarks plug in; no new format is invented.** The internal representation stays
minimal — prompt, scorer, metadata — with thin adapters to `lm-evaluation-harness` task
YAML (the most widely available static-QA corpus) and `inspect-ai` (the better fit for
multi-step and agentic tasks, and the one gaining adoption). HELM is too heavy to sit in
the middle, OpenAI Evals is effectively stalled, BIG-bench is frozen and is a data asset
rather than a runner. Only the *result* schema is ours, and it is stabilised so
conversions stay possible.

**Burn-in results are short-lived.** Record the resolved model version, never the alias.
Run a fixed canary set weekly and treat a drift beyond the measured flip-rate floor
(1.7–20% per cell) as invalidating the burn-in. Assume weeks, not months.

## What the implementation probe changed

The effort axis was declared in `pool.yaml`, expanded into arms, and probed against the
live deployment before anything was built on top of it. Ten members became nineteen
arms, all nine non-default levels were accepted, and the dial behaves as hoped — for
one economics question, `gpt-5.6-sol` went from 7 completion tokens at `none` to 380 at
`high`, a 54-fold cost range inside one model, and the answer changed from wrong to
right between `none` and `low`. That is a larger accuracy-cost trade than anything the
model axis produced in v1, which is why this axis is the one that cannot be cut.

Three findings from the same probe change the plan.

**Streaming is mandatory, not optional.** `grok-4.6@high` spent the entire 2048-token
budget on reasoning and emitted no answer; at 4096 it did the same and took 45 seconds;
at 8192 the gateway returned 502. The cause is in the gateway and is deliberate: the
non-streaming read window is capped at 50 seconds
(`MANTLE_NONSTREAM_READ_TIMEOUT_SECONDS`) so that a slow call fails as a parseable JSON
502 rather than as a CloudFront HTML 504 at the CDN's 60-second origin timeout. The same
code notes that **streaming keeps the long window**, because the CDN's timeout then
applies per read. So the high end of the effort dial is unmeasurable on the
non-streaming path. A review round concluded streaming was droppable if only cost and
accuracy were wanted; that is true only if the high-effort arms are given up, and those
arms are what the primary estimand is about.

**The completion budget is a cap, not a charge.** Raising it costs nothing for an arm
that stops at 200 tokens, and only the arms that use it pay. v1's 2048 was calibrated on
default-effort arms and silently truncates the high-effort ones, scoring them as wrong
for running out of room. The budget goes up until `finish_reason = length` is rare for
every arm, and actual tokens remain the cost.

**The dominance argument for dropping the self-hosted member does not survive.** One
review round proposed skipping the cross-region work entirely on the grounds that the
self-hosted arm is dominated on both axes and so cannot affect Δ. It is dominated *at
`--max-num-seqs=2`*. To stop being dominated it needs a blended price under $4.84/Mtok
against the $8.83 measured, which is **1.82x** the throughput it showed — and the
roofline for four L40S at fp8 puts that at a batch depth of about seven, against a vLLM
default of 256. The arm is a plausible frontier member, the load sweep decides it, and
the cross-region path stays in scope.

## Implementation decisions, after review

| Item | Decision |
| --- | --- |
| Reachability | Cross-region PrivateLink: internal NLB in ap-northeast-1, interface endpoint in us-east-1, so `VLLM_ENDPOINTS` keeps pointing at a private address. A public NLB restricted by NAT egress IP is rejected — an IP is not an identity, and an NLB in TCP passthrough in front of a plaintext vLLM would put prompts on the public internet in the clear. |
| Gateway change needed anyway | Per-endpoint connect/read timeouts. The vLLM transport's `read 8.0s` will cut exactly the saturated operating points the load sweep exists to find, and dropping only the slow calls biases the measured price downward. "PrivateLink needs no gateway change" is false, which narrows the gap to adding per-endpoint bearer auth. |
| Cost model | Headline is the saturated replacement price at the highest-throughput point that meets the tier's SLO. Average realised and marginal spare-capacity are analysis columns. Prefill/decode split is deferred: under chunked prefill and continuous batching the two phases interleave in one step, so additivity fails and a single fitted pair is fiction — a two-level input-length probe at fixed output length gives the ratio instead. `serving_cost.py` raises rather than returning a split the sweep cannot identify. |
| Arrival process | Open-loop Poisson as primary; a closed loop at fixed concurrency self-throttles and cannot find the rate at which the queue runs away. Burst sensitivity alongside, because Poisson is kinder than production. The measurement yields *capacity*, never utilisation — utilisation is demand-side and stays an empty column until real traffic fills it. |
| Setting selection | The SLO picks the batch depth, which removes the "tuned to look cheap" objection. But picking the best setting from a noisy sweep has a winner's curse, so the chosen setting is re-measured independently before its price is used. |
| Cross-fitting granularity | At **arm** granularity, not model. A model with five effort levels gets five chances to place a lucky point on the frontier and a model with two gets two, so the all-models frontier is more selection-biased than the single-model one and Δ is biased upward. Choosing the arm on one fold and scoring it on another is the only thing that removes it. |
| Arm death | A provider rejecting an effort level mid-run is recorded as the arm ceasing to exist, not as a missing answer — providers change the supported set without notice, and scoring a shrunken arm on a subset would break comparability silently. Implemented in the client. |
| Reasoning-token accounting | Some providers report reasoning tokens in usage and some do not, which distorts the frontier where cost is billed on them. Reconcile usage against the billing export before any cost claim on the effort axis. |

## Implementation status

Written down because the plan above is longer than any one sitting, and the next
person to open it — including a later version of the same session — needs to know
which half is code.

Built and tested (`bench/tests`, 69 cases):

- The arm as the unit: `catalog.Arm` and `catalog.arms()` expand the pool's
  `effort_levels` declaration, and an undeclared member gets the default level only.
- The collection path is arm-aware end to end: `runner.Task` carries the effort,
  `pinned_tasks` and `repeat_tasks` are built from arms, arms of one member share
  that member's in-flight gate, and `--resume` keys on the arm name so a resumed run
  does not re-pay for `@high` because `@low` finished.
- Streaming is the default path, with `--no-stream` kept only for reproducing a v1
  number.
- Arm retirement: a 400 that names the effort level retires the arm for the rest of
  the run, re-checked when a queued cell reaches the front, so the waste is bounded
  by the concurrency rather than by the length of the task list. The predicate reads
  the provider's named parameter when there is one, because a body that merely
  enumerates the accepted fields would otherwise retire a working arm.
- The completion budget is a cap and reported as one: every run prints the per-arm
  rate of `finish_reason = length`, and the default cap is 16,384 rather than v1's
  2,048, which the effort probe showed binding at the top of the dial. Raising the
  cap moved the deadline problem into view, so on the streaming path the deadline is
  now idle time rather than total duration, and a stream that breaks after producing
  tokens is kept as a partial instead of being retried and billed twice.
- Every row records the settings it was measured under, and a run refuses to append
  to a file collected under different ones. Without this the effort axis was
  unmeasurable in the worst way: a v2 default arm has the same name as the v1 member,
  so a resumed run would have silently compared a 2,048-token non-streaming row
  against a 16,384-token streaming one and called the difference reasoning effort.

Three rounds of adversarial review on that code — two with one reviewer, one with a
second and independent one — changed it in ways worth recording,
because each was a way of paying for a matrix that answers a different question:

- The first fix for the deadline problem used a per-read socket deadline. That is
  wrong twice over — a keep-alive comment is a byte, so a hung upstream looks alive,
  and the first body byte legitimately takes minutes on a provider that buffers its
  thinking, so it would cut the slowest arms and bill for them. The deadline is now a
  watchdog on SSE events with a separate first-event window and a loose ceiling.
- Retrying a timeout pays twice for work the provider had already done and gives that
  question a second sample no other arm got. Only connection failures that produced
  nothing are retried now.
- The retirement predicate matched any mention of the effort field, so a 400 that
  merely lists the accepted parameters would have retired a working arm.
- Failures are counted per arm, because a failed cell counts as collected: an outage
  landing on one arm shortens it permanently and moves the run's total hardly at all.
- Retirement was in memory only, so a restart or a resume bought the dead arm's
  remaining questions all over again. It is read back from the rejection rows now, and
  an arm that has not yet answered sends one call at a time, which bounds the cost of
  discovering that an arm is gone at one call instead of one per concurrency slot.
- The completion cap is not free. "A cap is not a charge" assumes the model does not
  expand to fill it, which is exactly what a reasoning arm does — so raising the
  default from 2,048 to 16,384 multiplied the worst case by eight. Every run now prints
  the ceiling it could reach and `--max-spend-usd` refuses to start above a limit.
- The line between "this arm was worse" and "this arm was measured differently" moved
  out of the runner and the CLI into `harness/quality.py`, because the analysis has to
  apply the same policy and should not import a CLI to find it.

Not built yet, in the order the plan needs them:

0. **A re-collection mode for failed cells.** The pairing assumes every arm answered
   every question, and nothing currently repairs an arm that lost cells to an outage.
   It is listed first because the power design below assumes equal sampling, and it
   needs an answer on the analysis side too — a re-collected cell has to supersede the
   failed one rather than appear beside it.
1. **The analysis side is still member-granular.** `policies.load_matrix` and
   `analyze.py` key on members, so the arm-level frontier, the utility contests at
   λ, and arm-granular cross-fitting have no home yet. This is the largest piece and
   it gates every number v2 reports.
2. **The three preconditions**, none of which is code today: the power analysis for
   a small Δ (pure computation on the v1 matrix, no spend, and it decides the price
   of everything after it), routing cost in dollars, and a temporal held-out.
3. **The load sweep and the cross-region path** for the self-hosted arm, which the
   dominance argument no longer disposes of.

## How the power analysis has to be done, and why it may end the plan

Condition 1 is the next piece of work. It starts as pure computation on the v1 matrix,
which costs nothing, but it cannot finish there — v1 measured the model axis, and the
quantity that decides power is the discordance *between a member's own effort levels*,
which no v1 row observes. Treating v1's between-member discordance as a stand-in
assumes the two axes behave alike, and the reason for running v2 at all is the probe's
finding that they do not. So the design is: the v1 computation is a screen that can
only reject, and a small arm-level pilot — a few dozen questions across a handful of
members at every declared level — supplies the discordance, the cost tail and the
per-arm failure and truncation asymmetries that the real calculation needs.

The form it has to take, after review:

The estimand is a paired per-question difference, `D_q = u_frontier(q) − u_best(q)`,
averaged over questions. Pairing is the whole design: the question main effect — by far
the largest variance component — cancels inside `D_q`, and what remains is the
question-by-arm interaction, which is simultaneously the source of any routing gain and
the dominant remaining variance. Both sides are selections, so both must be cross-fitted
on the same split, or the winner's curse inflates Δ̂ and can flip its sign.

Power is then not a function of accuracy but of **discordance**: the share of questions
where exactly one side is right, the McNemar structure. Cross-fitting has to happen
*inside* the bootstrap — every resample re-runs the frontier choice, the best-arm choice
and any policy fitting, and resamples whole questions as clusters — or the interval
omits the selection variance that is the largest thing being estimated.

Flip rate enters as measurement error and is unbiased in the mean, so it does not shrink
Δ̂ — it inflates the variance, which means the answer is more samples per cell rather
than a correction to the estimate. That holds only while the error is symmetric across
arms, and here it is not guaranteed to be: parse failure, truncation and timeout all
vary with effort level, and any of them landing asymmetrically moves the mean rather
than the variance. So the flip variance is estimated per arm and per failure mode, and
an asymmetry is treated as bias to be removed rather than noise to be averaged. v1 has
repeat data, so the flip term is a measured plug-in for the model axis; the effort axis
needs the pilot. The λ-utility versions have a heavy right tail in cost, so the primary
estimator has to be pre-registered as winsorised or log-cost, with question-level
percentile-t bootstrap rather than a normal approximation, and one λ chosen in advance or
a simultaneous band over the grid.

The order-of-magnitude check is discouraging and is the reason this is a gate rather
than a formality. At a discordance of about ten percent, the standard error on 693
questions is roughly √(0.1/693) ≈ 1.2 points, so the smallest detectable Δ at eighty
percent power is around 3.4 points. The Δ this experiment is looking for is one to two.
On the temporal held-out slice, which is smaller than the full fold, it is worse. So
either the design changes — more questions, three or more samples per cell, category
stratification, regression adjustment on v1's own difficulty estimates — or v2 does not
run. The final number should come from simulation over a fitted question-random-effect
model with the measured flip rates and the measured token-cost tail, sized on the
held-out slice, not from a closed-form calculation on the whole fold.

## The decision after the pilot

v2 was conditional on three things, and the first one answered a question the plan had not
thought to ask. The power work says the design is affordable at a two-point target. The
pilot says the mechanism the design would measure is absent from this benchmark: on
MMLU-Pro the compute dial has a single notch, `off` to `on`, and every step above it moves
cost by up to nine times and accuracy not at all — by less, in a paired test, than the
same arm moves when asked a second time.

That makes Δ ≈ 0 not merely an acceptable outcome but a near-certain one, and for a reason
that is about the dataset rather than about model diversity. Spending 1,200 questions and
three asks to put a tight interval around zero would buy a correct number and no insight.

**So the next spend goes to a task family where the dial has range**, and the pilot
protocol becomes the screen that decides whether it does — twelve arms, 137 questions, a
repeat pass, `power.py --pilot`, about $28 and forty minutes. Candidates in the order they
are likely to have range: long-form generation scored by a rubric, multi-step or agentic
tasks where an error compounds, and code with tests as the scorer. What makes them
different from MMLU-Pro is that the answer is not a letter of the alphabet, so a longer
chain of thought has somewhere to go.

The rest of this plan stands. If a task family clears the screen, the estimand, the
cross-fitting, the arm granularity and the three conditions apply to it unchanged — and
the harness now collects it.

## Explicitly not in v2

- **Per-step routing inside an agentic task.** Probably where MoM's real value is, and
  therefore its own experiment. Mixed into v2 it would destroy comparability with v1 and
  read as changing the subject after a negative result.
- **A per-domain quality matrix as the router's centrepiece.** It is a diagnostic and a
  hierarchical-model random effect, not the mechanism. Putting the feature v1 killed back
  at the centre under a new name is the first thing a reviewer would notice.
- **Continuous online learning.** It breaks reproducibility, which is the one thing this
  harness has.

## Why the failure case is the valuable one

If v2 shows that two strong models, a thick effort axis, and feature-conditioned
allocation still cannot break the unconditional frontier by more than the cost of
routing, that is a considerably stronger contribution than a narrow win would be. The
design should be built so that outcome is reportable without embarrassment, because on
the evidence so far it is the more likely one.

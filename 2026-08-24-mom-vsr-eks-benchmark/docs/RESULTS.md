# Mixture-of-Models on EKS — results

Held-out result, 693 MMLU-Pro questions across seven categories, ten pool members
reached through one gateway, all arms on the same data path.

**Routing did not buy accuracy. Choosing a better single model bought 40% of the
cost.** The router's own selector ended up naming one member for 96% of requests,
which is what a selector that cannot express per-domain strength does. An offline
per-domain assignment, fitted on a separate fold, looked good where it was fitted
and lost 2.5 points where it was scored.

## The headline table

Scored on the test fold against the most accurate member on the calibration fold
(`claude-fable-5`). "No worse" is a one-sided non-inferiority test at a 2-point
margin fixed before the fold was opened, not an interval that happens to contain
zero.

| Arm | Accuracy | $/question | Δ accuracy | No worse? | Cost | Latency |
| --- | --- | --- | --- | --- | --- | --- |
| `claude-fable-5` (baseline) | 0.9062 | 0.00875 | — | — | — | — |
| **`global_static: claude-opus-5`** | **0.9105** | **0.00529** | **+0.0043** | **yes** | **−39.6%** | **−1.1 s** |
| `domain_static: true_label` | 0.8817 | 0.00635 | −0.0245 | no | −27.4% | +0.6 s |
| `routed: multi_factor` (VSR) | 0.8701 | 0.00321 | −0.0361 | no | −63.3% | **+12.8 s** |
| `cheapest: qwen3.8-27b` (self-hosted) | 0.6522 | 0.00010 | −0.2540 | no | −98.9% | −2.4 s |
| `random: uniform` | 0.7939 | 0.00487 | −0.1123 | no | −44.4% | −0.1 s |
| `oracle: any correct` | 0.9596 | 0.00487 | +0.0534 | — | — | — |

After Holm correction across the seven comparisons, six accuracy differences remain
distinguishable from zero; the one that does not is `global_static`, which is the
point of it.

## What the router actually did

| Member named | Share |
| --- | --- |
| `grok-4.6` | 96.2% |
| `qwen3.8-27b` | 3.2% |
| none (request failed) | 0.6% |

This is the structural limit of the selector, measured rather than argued. VSR's
`multi_factor` scores `wQ·quality + wL·latency + wC·cost + wLoad·load`, and its
quality term reads one static number per model card — there is no per-domain quality
in the schema. Given a global quality score and a cost weight, the arithmetic has
one answer, so the router names one member. It picked a good one: `grok-4.6` is
1.3 points off the best member at 38% of its price. But that is a fixed choice
dressed as a decision, and the 12.8-second latency penalty is what a reasoning
member's tail costs when everything is sent to it.

## Was there anything to route on? No.

A negative routing result has to answer which of two things happened: the labels
carried signal and the fitting missed it, or there was no signal to fit. That is
answerable from the matrix alone, at no further cost.

Take the ceiling for *any* domain-conditioned policy — the best member per domain,
chosen with hindsight on the scored fold — and compare it against the same quantity
with the domain labels shuffled.

| | Accuracy |
| --- | --- |
| Best single member (`claude-opus-5`) | 0.9105 |
| Ceiling for a perfect per-domain choice | 0.9177 (+0.72 pt) |
| The same ceiling with the labels shuffled | 0.9176 (95th percentile 0.9221) |

`p = 0.575`. **For accuracy, the domain labels carry no exploitable signal.** The
+0.72 points is what "best of ten per bucket" reaches from selection alone, and random
buckets reach it too. No quantity of calibration data would have produced a per-domain
policy that beat the best single member *on accuracy*, because there was nothing there
to calibrate to. The overfitting in the next section is the symptom; this is the cause.

### But scoring the blade on accuracy alone is a false negative for cost

Accuracy is the wrong quantity to hold the blade to, and this is the one correction
that changes a headline. A feature that predicts **difficulty** rather than **which arm
wins** cannot move an accuracy ceiling at all — every bucket still prefers the same
strongest arm — while being precisely what cost-aware routing lives on: send the easy
bucket somewhere cheap. So the same test is run on a utility, `accuracy − λ · cost`,
with λ swept rather than chosen. λ is what one accuracy point is worth per question,
inverted: λ = 5 values a point at $0.002 per question, λ = 100 at $0.0001.

| λ | Best single arm | Per-domain ceiling | Shuffled | p |
| --- | --- | --- | --- | --- |
| 0 (accuracy only) | 0.9105 | 0.9177 | 0.9176 | 0.578 |
| 5 | 0.8841 | 0.8908 | 0.8891 | 0.268 |
| **20** | 0.8162 | **0.8406** | 0.8249 | **< 0.001** |
| **100** | 0.6427 | **0.6744** | 0.6508 | **< 0.001** |

So the honest statement is narrower than the one above: **the domain label is worthless
to a router that only cares about accuracy, and carries real signal to one that cares
about cost.** Which is to say per-domain routing here is a cost optimisation — "this
domain is easy, send it somewhere cheap" — and never an accuracy one. Everything this
report measured was scored at λ = 0, which is why the fitted per-domain arm lost.

### How many members does the pool need?

| Pool | Existential ceiling | Gain |
| --- | --- | --- |
| `claude-opus-5` | 0.9105 | — |
| `+ claude-fable-5` | 0.9351 | +2.45 pt |
| `+ qwen3.8-27b` | 0.9466 | +1.15 pt |
| `+ gemma-4` | 0.9524 | +0.58 pt |
| `+ claude-sonnet-5` | 0.9553 | +0.29 pt |
| `+ grok-4.6` | 0.9582 | +0.29 pt |

Two members reach 0.9351 of the ten-member ceiling of 0.9596. The other eight buy 2.4
points of *existential* headroom between them, none of which any router reached. A pool
of ten was eight members wider than the evidence supports.

### The apparent per-domain differences are shared difficulty

Members do differ by domain — the mean deviation of a member's per-domain accuracy
from its own average is 6.7 points. But almost all of it is common to every member:
each one is 9 to 15 points better than itself on math and 5 to 24 points worse on
law. That is the domain being easy or hard, which is shared and therefore unroutable.
Routing needs **rank reversals**, and those appeared only among members too weak to
be chosen: `nemotron` is +14.2 on health against its own average while
`claude-fable-5` is −8.3, but nemotron's overall accuracy is 0.564, so being good at
health still does not beat `claude-opus-5`.

Among the members strong enough to matter, the errors are highly correlated:

| Pair | phi | Exactly one correct |
| --- | --- | --- |
| `grok-4.6` / `gpt-5.6-sol` | +0.704 | 46 of 693 |
| `claude-opus-5` / `claude-fable-5` | +0.680 | 37 of 693 |
| `claude-opus-5` / `gpt-5.6-sol` | +0.639 | 53 of 693 |
| `claude-opus-5` / `claude-sonnet-5` | +0.525 | 77 of 693 |

Between 37 and 82 questions out of 693 is the entire budget routing could win from
any pair, and it is not predictable from the domain.

## Why the per-domain assignment failed

Fitted on calibration, the rule chose five different members across the seven
domains and scored **+2.5 points** there. On the test fold the same frozen policy
scored **−2.5 points**. The swing is the overfitting the fold split exists to catch:
at 58–81 calibration questions per domain, the paired difference between members
carries a standard error of roughly three points, so "the best member for law" is
mostly noise.

The margin sweep confirms it is not an artefact of one threshold:

| Margin | Verdict | Δ accuracy | Cost |
| --- | --- | --- | --- |
| 0.00 | fail | −0.0231 | −22.2% |
| 0.01 | fail | −0.0245 | −27.4% |
| 0.02 | fail | −0.0245 | −27.4% |
| 0.05 | pass | −0.0245 | −27.4% |

It only passes where the margin is wide enough to make the test vacuous.

Per category, against the same baseline:

| Category | baseline | global_static | domain_static | routed |
| --- | --- | --- | --- | --- |
| computer science | 0.928 | 0.938 | 0.938 | 0.897 |
| economics | 0.927 | 0.917 | 0.917 | 0.908 |
| engineering | 0.894 | 0.894 | 0.894 | 0.800 |
| health | 0.824 | 0.843 | 0.804 | 0.804 |
| law | 0.854 | 0.906 | 0.792 | 0.802 |
| math | 1.000 | 0.982 | 0.973 | 0.955 |
| philosophy | 0.904 | 0.883 | 0.840 | 0.904 |

`domain_static` loses 6 points in law and 6 in philosophy — the two domains where its
calibration pick was most confident. The routed arm is worse than the baseline in six
of seven.

## Against the frontier a coin flip already reaches

Mixing two members at probability *p* lands exactly on the segment between their two
points in the cost-accuracy plane, so the upper-left convex hull of the ten
single-member points is available without any router. That hull, not the best single
member, is the line a router has to clear.

| Arm | Gap to the hull |
| --- | --- |
| `routed: multi_factor` | −0.0066 CI[−0.0218, +0.0089] |
| `domain_static: true_label` | −0.0289 CI[−0.0491, −0.0087] |
| `oracle: cheapest correct` | +0.2467 CI[+0.2221, +0.2703] |

The router sits **on** the hull — its interval straddles zero — which is the precise
statement of "it bought nothing that a coin flip between two models would not have".
The per-domain assignment sits measurably below it. The hull is refitted inside every
bootstrap resample, so these intervals carry the hull's own uncertainty; treating it
as a fixed line would have biased the gaps against the router.

## How much was there to win

The existential bound — correct wherever any member was correct — is 0.9596, only
**5.3 points** above the best single member. And ten independent guessers over
ten-option questions reach 0.6513 between them while knowing nothing, so a large part
of any such bound is the answer format rather than the pool. This is a bound chosen
after the answers are known; no input-time router is guaranteed to approach it.

So the ceiling for perfect routing over this pool on this benchmark is about five
points, and the measured cost of trying was two to four points. That ratio, not the
router's implementation, is the reason the negative result is unsurprising in
hindsight: these members largely succeed and fail on the same questions.

### Part of that ceiling is coin flips

Because no temperature is legal across this pool, every member decodes at its own
default and none is deterministic. Re-asking 120 test questions gives the per-cell
disagreement rate directly:

| Member | Flipped on a second ask |
| --- | --- |
| `qwen3.8-27b` (self-hosted) | 20.0% |
| `nemotron-super-3-120b` | 15.8% |
| `qwen3-next-80b` | 7.5% |
| `grok-4.6` | 5.0% |
| `gpt-5.6-terra` | 5.0% |
| `claude-sonnet-5` | 4.2% |
| `claude-opus-5` | 4.2% |
| `gemma-4` | 3.3% |
| `gpt-5.6-sol` | 1.7% |
| `claude-fable-5` | 1.7% |

An existential bound is a chain of "did anyone get this right", so it gains from every
independent flip. On the 119 questions with two full samples: the bound is 0.9580 from
one sample, and 0.9496 when a member must be correct in **both** samples — so about
**0.4 points of the headroom is single-flip luck**, and the honest headroom over the
best single member on that subset is +2.5 points rather than +3.4.

This also means the intervals elsewhere in this document are slightly narrower than
the truth: the bootstrap resamples questions but treats each member's verdict on a
question as fixed, when a second ask would change it a few percent of the time. It
does not change any conclusion here — the routing losses are two to four points
against flip rates of a few percent — but a study claiming a one-point win over this
pool would need repeated sampling per cell to claim it.

## What this says operationally

1. **Look at the single-model frontier before building a router.** `claude-opus-5`
   was both more accurate than `claude-fable-5` and 40% cheaper. That is the whole
   saving, and it needs no routing machinery — just measurement.
2. **A cost-aware selector over a global quality score is a model-choice tool, not a
   router.** It works, in the sense that it found a cheap good member. It should be
   described that way.
3. **Test whether routing can pay before building a router.** The shuffled-label
   ceiling is one pass of the pool over one fold and costs nothing beyond the matrix.
   Here it said the domain labels were worthless before any policy was fitted, which
   would have saved the fitting. It belongs at the front of a routing project, not the
   end. `analyze.py` reports it.
4. **Cheap does not mean free.** The routed arm was 63% cheaper and 12.8 seconds
   slower per request, because the cheap accurate member is a reasoning model with a
   long tail.

## Correction: the self-hosted member was not the cheap option

The rate table prices the self-hosted member at a flat $0.20 per million tokens, in
both directions, with no note and no derivation. Nothing in the gateway models
utilisation, throughput or GPU-hours. That number is a placeholder, and it is wrong
by a factor of about forty.

A self-hosted model is a capacity commitment, so its per-token cost is
`GPU $/hour ÷ tokens/hour achieved` — a function of load, not a constant. Measured on
the run itself: the pod is one `g6e.12xlarge` (four L40S, $15.2174/hour in
ap-northeast-1) serving `--max-num-seqs=2`, and it sustained **220 output tokens per
second**. At full utilisation that is:

| | $/Mtok |
| --- | --- |
| Effective, output tokens | **19.20** |
| Effective, all tokens | **8.80** |
| What the rate table assumed | 0.20 |

To reach parity with `grok-4.6` at $6.60/Mtok output it would have to sustain 640
output tokens per second — about **three times** the measured throughput, or 2.9
questions per second forever. At the configuration actually deployed, the self-hosted
member was **more expensive than most of the commercial pool**, not cheaper.

What that changes, and what it does not:

| Claim | Status |
| --- | --- |
| `global_static: claude-opus-5` is 39.6% cheaper at no accuracy loss | **unaffected** — both members are Bedrock list prices |
| The routed arm is 63.3% cheaper | **−61.9%** once the self-hosted rate is corrected |
| The routed arm sits on the mixture hull | **unaffected** — the hull segment it sits on is unchanged |
| `cheapest` member is the self-hosted Qwen at −98.9% | **withdrawn** — it is `gpt-5.6-terra` |
| The self-hosted member is on the mixture hull | **withdrawn** — it is dominated: 0.652 accuracy at $0.0042 against `gpt-5.6-terra`'s 0.834 at $0.0023 |

The routed arm's saving barely moves because only 22 of 695 requests (3.2%) went to
the self-hosted member; the saving was always concentration on `grok-4.6`. But the
placeholder rate did put a dominated member on the hull, which flattered the
frontier's cheap end.

`--max-num-seqs=2` is a self-inflicted ceiling, so this is not a verdict on
self-hosting — it is a verdict on this deployment, and on quoting a per-token price
for a machine you rent by the hour.

## Scope and limitations

- One benchmark (MMLU-Pro), seven categories, ten-option multiple choice. Frontier
  members are near ceiling in some categories, which compresses the differences a
  router could exploit. A generative or agentic task could differ.
- Accuracy is measured at each member's own decoding defaults, because no temperature
  value is accepted by every member in this pool. That costs determinism.
- Cost is the gateway's rate table, in dollars. It is not compute: three members are
  deliberately over-charged because Bedrock publishes no list price for them, so a
  cost-aware selector avoids them for a reason that is about the rate table.
- Six of 699 test questions were dropped because one member failed on them, and they
  were harder than average (mean member accuracy 0.630 against 0.794), so every
  accuracy here is slightly optimistic.
- The router's semantic cache is enabled but served no hits: all 12,555 scored calls
  report `x-vsr-response-path: upstream`, which the analysis enforces rather than
  assumes.
- Total measurement: 12,569 calls, 5.33M gateway-charged tokens, $61.01.

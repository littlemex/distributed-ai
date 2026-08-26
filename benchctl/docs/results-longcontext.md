# Long context, and the correction it forces

Measured 2026-08-27, same box as the classification family (Qwen3.6-35B-A3B-FP8, TP=2 x 2 replicas,
$15.2174/h), same baseline (`claude-haiku-4-5`). Items: 24 from LongBench-v2 filtered to fit the 262k
window — real long documents, a four-way question, a one-letter answer, so exact-matchable without a judge.
Median context 68,000 to 86,000 characters; haiku billed about 20,600 input tokens per item.

**A public benchmark, not held-out production traffic.** It settles the economics of the *shape*; `p_i` for
a real workload still has to be measured on that workload.

## Quality: the box is well ahead, again one-directionally

| | box | haiku |
| --- | --- | --- |
| passed | **14/24 = 0.583** | 10/24 = 0.417 |
| paired: only baseline / only box | **0 / 4** | |
| difference | **+16.7 pp**, one-sided 80% lower bound +8.3 | |
| McNemar exact p | 0.125 (four discordant pairs, all the box's way) | |
| latency p50 per item | 1.95 s | 2.17 s |

Chance is 0.25 on a four-way choice, so both layers are above it and the box clearly further. As in the
classification family, haiku never won an item the box lost — two families in a row where the box's
successes contain the baseline's.

## The economics, and the prediction they refute

I had written that this family was where the money is, on the argument that the box's input is a quarter of
the cheapest API's while its output is barely cheaper, so the saving per request scales with input length.
The first half is right and the conclusion does not follow.

| | classification | long context |
| --- | --- | --- |
| shape (haiku-billed) | 298 in / 8 out | 20,594 in / 4 out |
| saving per request | $0.000280 | **$0.013504** — 48x more |
| box seconds per request | 0.014 | **1.682** — 120x more |
| **saving per box-second** | **$0.0200** | **$0.0080** |
| best requests/hour | 264,194 (c=64) | 2,140 (c=16) |
| **API spend avoided per box-hour** | **+$74.10** | **+$28.90** |
| vs the box's own $15.22 | 4.9x | 1.9x |

**The saving per request is 48 times larger and the value per box-hour is 2.6 times smaller**, because the
objective divides by box time and box time grew 120-fold. What I got wrong was treating "the saving scales
with input length" as sufficient; the quantity that decides admission priority is saving per box-second, and
that runs the other way.

The mechanism is measurable rather than hand-waved. Expressed as the API-billed tokens the box can retire
per hour:

| | effective read rate | API spend avoided per hour, gross |
| --- | --- | --- |
| classification | 21,869 tok/s | $89.3 |
| long context | 12,242 tok/s | $44.1 |

The box reads short prompts at nearly twice the tokens per second it reads long ones. Ten of its forty
layers are full attention, whose cost is quadratic in length, so a 20,000-token prompt costs more than
sixty-six times a 300-token one rather than sixty-six times exactly. API prices are linear in tokens. A
linear price against a super-linear cost is the whole result.

### With quality weighted in, this family does not pay for itself

The objective's numerator is `p_i · C_api`, not `C_api`: an item the box answers unacceptably still consumes
box time, and the request then goes to the API anyway, so it avoids nothing.

| family | p_i (measured) | net per box-hour | vs the box's cost |
| --- | --- | --- | --- |
| classification | 0.979 | +$72.4 | 4.8x |
| long context | 0.583 | **+$10.52** | **0.7x — below its own cost** |

At a 58% acceptance rate this family cannot pay for the machine, even though the box beats the baseline on
it by sixteen points. Two separate things have to be true for offload to earn, and only one of them is:
the box is *better* here, and it is still not *worth it* here.

## What this changes

* **Admission priority is saving per box-second, and it must be measured, not reasoned about.** Both the
  per-request saving and the box time have to come from measurement, because they move in opposite
  directions with input length and the ratio is not predictable from prices alone.
* **The published guidance was wrong and is corrected.** The explainer's fourth chapter said the prime
  target was batch long-document work. It is not, for this box: quadratic attention on long prompts costs
  more box time than the linear API price saves.
* **Long context is still worth serving for a different reason.** The box answers these 16.7 points better
  than haiku and slightly faster. If the requirement is quality on long documents rather than saving money,
  this is a good place for it — it just should not be sold as the cheap option.
* **The knee moved with the shape.** Long prompts saturate at four to sixteen in flight and TTFT p50 reaches
  19.8 s at sixteen; short prompts saturate at sixty-four with TTFT under a second. One admission rule
  cannot cover both, so the operating point belongs to the family and not to the box.

## What is still missing

* Held-out production traffic for both families.
* A middle shape. Two points do not describe a curve, and the crossover — where saving per box-second stops
  favouring shorter prompts — is unmeasured. Somewhere between 300 and 20,000 input tokens is the shape
  worth admitting first.
* The output-heavy corner. Both families here write almost nothing; a family that writes a lot would price
  differently, and the box's output advantage over haiku is only 18%.

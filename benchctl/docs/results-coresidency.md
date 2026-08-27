# Co-residency: which knob actually protects a short family

Measured 2026-08-27 on the same box (Qwen3.6-35B-A3B-FP8, g6e.12xlarge, $15.2174/h, vLLM 0.27.1,
TP=2 x 2 replicas, `max_num_seqs=256`, `enable_prefix_caching=False`). Short family: 300 input / 8
output at 64 in flight. Long family: 20,000-token prefills, a fixed number of them resident.

`results-shape-surface.md` established that a short family loses 0.35x of its throughput and 5.85x of
its TTFT p95 to two co-resident long prefills, and read the box's total earnings as barely moving. The
question here is which knob fixes it — and the answers turn out to be that one engine setting helps a
lot, one does nothing, the setting that would matter does not exist in this version, and the "earnings
barely move" reading was an artifact of never measuring the box with no long work on it at all.

## I was turning the wrong knob

The first attempt cut `max_num_batched_tokens` from 16,384 to 2,048 and recovered only a third of the
damage while making the pure-short case worse. Reading `vllm/v1/core/sched/scheduler.py` says why, and
the two settings that look alike are not:

| | what it bounds | effect |
| --- | --- | --- |
| `max_num_batched_tokens` | the **step's total** budget (`token_budget = self.max_num_scheduled_tokens`) | shrinking it shrinks the step for every request, decodes included |
| `long_prefill_token_threshold` | **one request's** share of a step (`if 0 < threshold < num_new_tokens: num_new_tokens = threshold`) | a long prefill advances a slice per step; the rest of the budget stays available |

The scheduler walks `self.running` first and `self.waiting` with whatever budget is left. So with a
16,384-token step and a 2,048-token per-request cap, a 20,000-token prefill takes 2,048 per step and
14,336 remain for short prefills and decodes in the *same* step. Cutting the total budget instead
starves everyone: at 2,048 total, a step holds about six 300-token prefills instead of about fifty.

## Six arms, one shape of answer

`θ` is `long_prefill_token_threshold`; `L` is the number of long requests resident.

| arm | θ | policy | L | short TTFT p95, mixed | short throughput ratio | long done | net $/box-hour |
| --- | --- | --- | --- | --- | --- | --- | --- |
| A | off | fcfs | 2 | 5.60 s | 0.346 | 34 | +36.81 |
| B | off, step budget 2,048 | fcfs | 2 | 4.82 s | 0.380 | 32 | +41.94 |
| C | 2,048 | fcfs | 2 | **1.99 s** | 0.515 | 17 | +40.74 |
| C repeat | 2,048 | fcfs | 2 | **2.08 s** | 0.467 | 16 | +38.17 |
| D | 2,048 | priority (long=100) | 2 | 1.72 s | 0.501 | 18 | — |
| E | 2,048 | priority (long=100) | 16 | 11.03 s | 0.092 | 158 | +38.57 |
| F | 2,048 | fcfs | 16 | 9.81 s | 0.100 | 176 | +42.57 |

Three results, in order of how much they change the design.

### The per-request cap works, and it is the only engine setting that does

Co-resident short TTFT p95 goes from 5.60 s to about 2.0 s, and the pure-short tail is not the price:
measured repeatedly under the same offered load it sits at 0.73 to 0.84 s, with one anomalous reading
of 1.83 s. That outlier landed in the denominator of arm C and produced a reported degradation ratio of
1.09x, which flattered the result. Against the stable baseline the remaining penalty is about **2.7x**,
not 1.09x — still the difference between a broken tail and a tolerable one, but not the near-elimination
the ratio suggested.

### Priority scheduling does nothing here, and the reason generalises

D is indistinguishable from C and E from F. `--scheduling-policy priority` orders the **waiting**
queue and picks the **preemption victim**; it does not reserve step budget, and it does not evict a
long prefill that is already running. Once a long request is in `self.running` it takes budget ahead
of anything waiting, whatever its priority, and with KV to spare nothing forces a preemption. So
priority is a knob for contention over admission, not for interleaving inside a step.

That kills a reframing I had published as open. The hope was that long work told to fill only slack
would have a marginal box cost near zero, which would turn the long-context family's +$10.52 per
box-hour from "below its own cost" into free upside. It does not hold: at saturation the long family
consumes box time it does not give back, and the near-constant net value across all six arms is
**conservation of box time, not a free lunch** — the same busy GPU reallocated between two families.
Marginal cost approaches zero only in hours when the short family is not filling the box, and
reaching that needs an admission gate outside the engine, not a priority field.

### The number of resident long requests dominates everything

At L=16 every configuration collapses to the same place — p95 about 10 s, short throughput at a
tenth — regardless of θ or policy. Sweeping L with θ=2,048 and fcfs:

| L | short TTFT p95, mixed | short throughput ratio | long completions | net $/box-hour |
| --- | --- | --- | --- | --- |
| 1 | **1.48 s** | 0.599 | 9 in 34 s | +44.03 |
| 2 | 1.99 / 2.08 s | 0.49 | 17 in 45 s | +38 to +41 |
| 4 | 2.78 s | 0.292 | 37 in 71 s | +39.32 |
| 8 | 4.00 s | 0.183 | 80 in 114 s | +43.11 |
| 16 | 9.81 s | 0.100 | 176 in 224 s | +42.57 |

Net value stays inside $38 to $44 across the whole sweep, which looked like a clean separation of
concerns: L as a service-level dial and not an economic one, with value density conserved and
therefore blind to the mixing decision. **That reading was wrong, and it was wrong because every arm
in the table has long work in it.** Adding the arm with none of it, and measuring goodput rather than
throughput, is the next section.

vLLM V1 has no setting for L. `max_num_partial_prefills` and `max_long_partial_prefills` were V0
features and are absent from `SchedulerConfig` in 0.27.1, so two of the three flags recommended to me
did not exist to try. The cap has to live in the router: a semaphore on concurrent long requests,
with the rest queued or sent to an API.

## Prefill/decode disaggregation is the wrong tool for this box

Worth stating because it is the obvious thing to reach for and it is a trap here. Both advisors
rejected it independently and for the same reason, which is the one that matters:

* **The interference is long-prefill against short-prefill, not prefill against decode.** The short
  family emits eight tokens; there is almost no decode to protect. Split prefill from decode and both
  prefills meet again on the prefill worker, with the same scheduler and the same step budget. The
  problem moves rather than resolves.
* **The capacity split would fall the wrong way.** On a workload that is 99.5% input, dedicating one
  of two replicas to decode idles it and halves prefill capacity — which is where the queue is.
* **The transfer does not pay.** L40S has no NVLink, so KV would cross PCIe that TP=2 all-reduce is
  already using. Moving a 20,000-token request's KV to another replica in order to decode eight tokens
  there costs more than decoding them where the KV already is.

Disaggregation earns its transfer when long decode needs isolating from prefill, when the
prefill-to-decode ratio can be tuned away from 1:1, or when a decode SLO matters on its own. This
workload has none of those. Earlier measurements of vLLM plus llm-d on p6-b300 do not transfer: that
was long output on hardware where the transfer is nearly free.

The separation worth considering is by **shape** — a short replica and a long replica — which splits
the two prefill classes that actually contend.

## The frontier: what the short family gives up per long request served

Both advisors converged on a metric this repository had not been reporting: **SLO-qualified short
goodput at a fixed long service rate** — not how many short requests completed, but how many completed
*inside their deadline*, while the long family was served at a given rate. Average throughput and
average value density are conserved when box time is reallocated between families, so neither can see
the trade. Goodput can.

Measured with θ=2,048, fcfs, a 1-second deadline, and the same offered short load throughout. The
pure-short row is the one the previous table was missing.

| L | long served/h | short goodput/h | within 1 s | short TTFT p95 | net $/box-hour |
| --- | --- | --- | --- | --- | --- |
| **0** | 0 | **225,730** | **100%** | **0.80 s** | **+54.76** |
| 1 | 954 | 102,022 | 75.2% | 1.49 s | +33.75 |
| 2 | 1,632 | 66,515 | 63.7% | 1.43 s | +35.07 |
| 4 | 1,792 | 35,885 | 53.2% | 3.12 s | +28.49 |
| 8 | 2,200 | 15,339 | 40.3% | 4.31 s | +29.54 |
| 16 | 2,892 | 1,889 | 8.8% | 12.43 s | +37.95 |

The pure-short baseline is stable: four of the five runs measured it at 224,958 to 226,594 requests an
hour with 100% inside the deadline and p95 between 0.73 and 0.84 s. The fifth read 146,365 at 84.5%
with p95 1.91 s, and it is the same outlier that earlier made a per-request cap look like it cost the
dedicated case its tail. One anomalous baseline out of five is worth naming rather than averaging away.

### The exchange rate, and why it settles the question

| L | short on-time requests given up | per long request served | long value/h | short value lost/h |
| --- | --- | --- | --- | --- |
| 1 | 123,708 | **130** | $17.34 | $38.35 |
| 2 | 159,215 | 98 | $29.67 | $49.36 |
| 4 | 189,845 | 106 | $32.58 | $58.85 |
| 8 | 210,391 | 96 | $40.00 | $65.22 |
| 16 | 223,841 | 77 | $52.58 | $69.39 |

Serving one long request costs about **100 short on-time requests**. A long request avoids $0.018181
of API spend and a short one $0.000310, so one long request is worth 59 short ones and costs
roughly a hundred. **The trade loses money at every level tested**, and the loss is largest at the
first step: admitting a single resident long request takes the box from $54.76 per box-hour to $33.75.

So the earlier claim is corrected twice over. L is not "a service-level dial and not an economic one";
it is both, and the economic cost was hidden by comparing mixed arms only with each other. On a box
whose short queue is full, **the right number of resident long requests is zero.**

### The caveat that keeps this from being the whole rule — and it turns out to invert the answer

The short load offered throughout is 225,730 requests an hour, which is what saturates this box. It is
not an arrival rate. In hours when short demand does not fill the machine, the box time long work uses
is time nothing else wanted, its opportunity cost really is near zero, and the whole table above stops
applying. The frontier measures the saturated end of the curve, which is where the answer is "no long
work"; the answer at the other end is "as much as fits".

That is precisely the gate both advisors described, and the table gives it a threshold to key on: admit
long work only while short on-time goodput stays above what the short arrival rate demands, and stop as
soon as it does not. The same frontier at realistic arrival rates is the next section, and it reverses the
conclusion: below saturation, with the per-request cap set, long work is nearly free and is the only
thing that makes the box pay for itself at all.

Two further cautions to carry into it:

* **The 189,672 requests/hour short baseline is a saturated generator, not an arrival rate.** With the
  pure-short tail already at 0.73 s against a 1 s target, there is almost no headroom left to spend on
  co-residency, and any θ derived from it will look impossible. The back-calculation has to start from
  the real arrival rate, where the headroom is.
* **Preemption plus `enable_prefix_caching=False` is a hazard.** V1 preempts by recompute, so a
  preempted 20,000-token prefill is computed again from nothing. That is box time burned outright, and
  it would corrupt exactly the accounting the next measurement is trying to establish.

## Below saturation: the answer inverts, and the cap is what makes it invert

Everything above is closed loop — N requests in flight, a new one only when an old one returns. That
measures capacity and cannot measure a service level, because it is self-limiting: when the server slows
the offered load slows with it, so queueing never appears. Real traffic arrives on its own schedule, and
the entire question of whether there is slack for a second family only exists below saturation.

So: open-loop Poisson arrivals for the short family at a fixed rate, a fixed number of long requests
resident, a one-second deadline, sixty seconds per cell, seed fixed. The generator reports its own
honesty — offered rate against the rate asked for, and the worst submit lag — and across all thirty
cells it delivered within 0.4% of the asked rate with a worst lag of 12.9 ms, so these numbers describe
the server.

### Short work alone does not pay for this box

| λ (req/s) | short on time/h | within 1 s | net $/box-hour |
| --- | --- | --- | --- |
| 6 | 21,241 | 98–100% | **−8.63** |
| 18 | 64,347 | 100% | +4.73 |
| 31 | 110,584 | 100% | +19.06 |
| 44 | 158,056 | 100% | +33.78 |
| 56 | 200,896 | 100% | +47.06 |

The box holds a one-second deadline at every rate up to 56 requests a second, which is 200,896 an hour
— close to the closed-loop saturated figure, so nothing here is in a degraded regime. But **at a tenth
of capacity the box loses $8.63 an hour**: 21,241 short requests avoid $6.58 of API spend against a
$15.22 bill. Occupancy was always the whole argument; this is what the other end of it looks like.

### With the cap set, long work fills the gap for free

Same sweep, `long_prefill_token_threshold=2048`, against the same sweep with it off:

| λ | L | θ off: within 1 s | θ off: net | θ=2,048: within 1 s | θ=2,048: net | θ recovers |
| --- | --- | --- | --- | --- | --- | --- |
| 6 | 0 | 100.0% | −8.50 | 98.0% | −8.63 | |
| 6 | 1 | 71.8% | +18.20 | **98.0%** | **+18.88** | **+26.2 pp** |
| 6 | 2 | 54.2% | +29.13 | 87.4% | +30.27 | +33.2 pp |
| 18 | 1 | 71.7% | +24.21 | **99.8%** | **+27.64** | +28.1 pp |
| 18 | 2 | 50.0% | +27.51 | 85.2% | +34.53 | +35.2 pp |
| 31 | 1 | 70.0% | +28.44 | **97.1%** | **+36.62** | +27.1 pp |
| 31 | 2 | 47.3% | +29.37 | 67.6% | +31.97 | +20.3 pp |
| 44 | 1 | 58.7% | +27.70 | 79.2% | +37.75 | +20.5 pp |
| 44 | 2 | 30.8% | +21.69 | 53.3% | +28.33 | +22.5 pp |
| 56 | 1 | 44.9% | +23.63 | 63.0% | +33.81 | +18.1 pp |
| 56 | 2 | 25.6% | +18.16 | 19.6% | +11.15 | −6.0 pp |

**At a tenth of capacity, one resident long request costs the short family nothing** — 98.0% on time
with it and 98.0% without — and takes the box from −$8.63 to **+$18.88 an hour**. Two take it to
+$30.27 for 10.6 points of on-time delivery. The saturated frontier said the right number of resident
long requests was zero; below saturation the right number is as many as the deadline can absorb, and
long work is what makes the box pay for itself at all.

Both statements are true, and the variable that switches between them is short load. The gate:

* **λ below about 70% of capacity: admit long work.** It is nearly free at L=1 and cheap at L=2.
* **λ above it: stop.** At λ=56 the box earns +$47.06 on short work alone and +$33.81 with one long
  request resident, so the long work now costs money as well as latency.

### The mechanism, and why the cap is not optional

With the cap off, the fraction of short requests inside the deadline is **almost independent of the
arrival rate** — 71.8%, 71.7%, 70.0% at λ=6, 18, 31. That is not a capacity effect. It is the
probability that a short request arrives while a long prefill is monopolising a scheduler step: with a
16,384-token step budget and no per-request cap, a 20,000-token prefill claims an entire step, and
everything that arrives during it waits. The miss fraction is the long stream's duty cycle of doing
exactly that, and duty cycle does not care how often short requests arrive.

Which is why the cap fixes it and why nothing else does. Cutting the step's total budget shrinks the
step for decodes too. Priority orders the queue but does not stop a running prefill from taking the
budget. Only bounding one request's share of a step leaves room in the same step for the short work.

**"There is idle capacity, so background work is free" is false as stated.** Averaged over an hour the
box at λ=6 is ninety percent idle, and one resident long request still destroyed 28 points of on-time
delivery until the cap was set. Idle capacity is not the same as being idle at the instant a request
arrives, and the gap between those two is a scheduler setting.

### What is still open

* Long arrivals as a rate rather than a resident count. `L` here is a continuously-resident stream — at
  L=1 there is always a long prefill in progress. Poisson long arrivals would spend most of the time
  with none, which is a different and probably kinder regime.
* The replica split, still unmeasured. It is now clearly second choice: one pool with the cap and a
  router-side gate on short load holds the deadline at 97 to 100% for λ up to 31 while serving over a
  thousand long requests an hour, and a split would give up that pooling for isolation it does not need
  at those rates.
* Real arrival traces. λ here is Poisson and stationary; real traffic is bursty, and a burst is exactly
  when a gate keyed on average load would be wrong.

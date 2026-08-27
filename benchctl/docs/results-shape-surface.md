# The shape surface: where a box-second is worth the most

Measured 2026-08-27 on the same box as the two family results (Qwen3.6-35B-A3B-FP8, g6e.12xlarge,
$15.2174/h, vLLM TP=2 x 2 replicas). Same baseline, `claude-haiku-4-5` at $1.00 / $5.00 per Mtok.

The two families measured before are two points, and the question they left open is which shape to admit
first. This measures the surface between them: input length against output length, each shape at its own
operating point, reported as **API spend avoided per box-hour** — the objective's numerator over its
denominator, which is what admission priority is.

## What is being priced, and what is not

Prompts are synthetic padding, so **nothing here says anything about quality.** Quality is a property of
a family and not of a length; a 20,000-token prompt from LongBench and a 20,000-token prompt of filler
cost the same box time and have nothing else in common. The surface gives the economics; `p_i` comes from
the family's own quality cell and multiplies in afterwards.

The avoided cost is not estimated from the box's tokeniser. Every prompt was also sent once to
`claude-haiku-4-5` and its billed `prompt_tokens` recorded, because the two tokenisers disagree by up to
1.6x on Japanese text and the avoided cost is what the API would have charged, not what the box counted.

| asked | haiku billed |
| --- | --- |
| 60 | 90 |
| 120 | 135 |
| 300 | 270 |
| 600 | 495 |
| 1,000 | 795 |
| 3,000 | 2,295 |
| 8,000 | 7,045 |
| 20,000 | 18,141 |

The API bills about 60 to 70 tokens of its own framing on the shortest request, which is worth noting: at
the short end a growing share of the avoided bill is boilerplate rather than content.

## The surface, at each shape's SLO-bounded knee

Each cell climbed a concurrency ladder until either throughput gained less than 10% on a rung or p95 time
to first token passed 30 s, and the best rung inside the SLO is the operating point. Output length is
swept separately from input length and never summed into a token total, because reading is compute-bound
and grows super-linearly while writing is bandwidth-bound and batches well.

API spend avoided per box-hour, out=8. **Taken with `max_num_seqs=27` and a single-pod generator, both of
which turned out to bind** — see the next two sections. The shape of the fall-off toward long inputs
survives the correction; the absolute values are low, most at the short end:

| input (asked) | 60 | 120 | 300 | 600 | 1,000 | 2,000 | 3,000 | 8,000 | 20,000 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| $/box-hour | 42.3 | 46.9 | **50.0** | 44.9 | 43.5 | 35.6 | 34.3 | 26.6 | 31.6 |

| input | out=8 | out=64 | out=256 |
| --- | --- | --- | --- |
| 300 | **50.0** | 41.5 | **50.4** |
| 600 | 44.9 | 41.0 | — |
| 1,000 | 43.5 | 37.2 | 39.3 |
| 2,000 | 35.6 | 36.2 | — |
| 3,000 | 34.3 | — | 35.5 |
| 8,000 | 26.6 | — | 33.7 |
| 20,000 | 31.6 | — | 24.0 |

Two things hold across all three output bands:

* **Every shape measured earns more than the box costs**, from 1.6x at the worst corner to 3.3x at the
  best. There is no shape in this range where the box loses money at its own operating point — the
  ranking differs, the sign does not.
* **Output length barely moves the ranking.** The peak sits at the same input length in every band. A
  request that writes 256 tokens saves five times more per request and occupies the box about five times
  longer, and the ratio comes out flat. The earlier reasoning — that output is only 18% cheaper on the box
  so output-heavy work is bad for it — was arithmetic on prices without the denominator; at the knee the
  box's decode rate is about $2.09 per Mtok written, not $4.12, because decode batches far better than the
  earlier single-shape derivation assumed.

## The generator was the confound, and it manufactured half the peak

The table above says density falls off toward short inputs as well as long ones — an interior peak, which
is what both advisors predicted from fixed per-request overhead. Checking it destroyed half of it.

Running the *same* shape from two client pods instead of one produced 584,739 requests/hour against
425,879. So the number being reported as the box's ceiling was partly the client's. Making the generator
process-parallel and extending the ladder to 512 in flight got one pod to 442,760 — still short. A
three-pod generator with pod anti-affinity, 384 in flight in total:

| input | 1 pod | 3 pods | $/box-hour, 1 pod | $/box-hour, 3 pods |
| --- | --- | --- | --- | --- |
| 60 | 442,760 req/h | **530,880** | 42.3 | **53.8** |
| 300 | 210,242 req/h | **225,501** | 50.0 | **54.7** |
| 600 | 112,288 req/h | **118,075** | 44.9 | **48.0** |

**With a generator that can keep up, 60 and 300 input tokens are 1.6% apart.** The left-hand slope was
partly the measuring instrument's fixed cost per request, not the box's.

## And the engine's own seat count was the rest of it

Reading the engine's startup line to check whether prefix caching was on — it is not,
`enable_prefix_caching=False`, so the identical synthetic prefixes could not have been reused — turned up
the number that mattered more: `max_num_seqs=27`. Every measurement above offered 128 to 384 requests to an
engine configured to admit 27 per replica. Everything past 54 in flight was queueing outside the engine and
being reported as the box's ceiling.

`27` came from `profiles.env`, where the sequence count was derived from the window's KV arithmetic and
labelled, in that file's own words, a starting point rather than a measurement. Raising it to 256 and
re-running the three-pod fleet:

| input | 27 seats | 256 seats | gain | $/box-hour at 27 | **$/box-hour at 256** |
| --- | --- | --- | --- | --- | --- |
| 60 | 530,880 req/h | 708,039 | **1.33x** | 53.80 | **+76.83** |
| 300 | 225,501 req/h | 265,792 | 1.18x | 54.69 | **+67.18** |
| 600 | 118,075 req/h | 123,890 | 1.05x | 47.95 | **+51.06** |

**The interior peak is gone.** With the generator and the engine both out of the way, density falls
monotonically with input length across the whole measured range: $76.83 per box-hour at 60 input tokens
against $51.06 at 600 and $24 to $32 at 20,000. At its best the box retires five times its own hourly cost.

The gain is largest exactly where the request is shortest, which is the signature of a per-request seat
limit rather than a compute limit: short requests need many seats to fill the machine and long ones do not.
So the earlier "peak at 300 to 600 tokens" was two artifacts stacked — a generator that could not keep up
and an engine that would not let it — and the truth underneath is the simpler shape.

**Any throughput number is a lower bound unless it names both the generator and the engine's seat count.**
That is the reason `sglang.benchmark.serving` is still on the list: a stand-in that saturates before the
server does reports the stand-in. And a configuration derived from geometry is a hypothesis; this one cost
33% of the box's value at the short end for as long as it went unchecked.

## Mixed shapes: value is additive, latency is not

Knees were found one shape at a time, and an admission rule mixes shapes. Measured directly: the short
family at 64 in flight, alone, and then with two 20,000-token prefills resident.

| | requests/hour | TTFT p50 | TTFT p95 |
| --- | --- | --- | --- |
| short alone | 189,672 | 0.46 s | 0.96 s |
| short with two long prefills resident | **65,614** | 2.42 s | **5.60 s** |
| ratio | **0.35x** | 5.3x | **5.85x** |

Thirty-four long requests finished alongside. The box-time ledger came out conserved: 70.2 s − 24.3 s =
45.9 s over 34 long requests is 1.35 box-seconds each, against 1.397 measured for that shape on its own.
And the combined value density, $37.3 per box-hour, is the box-time-weighted average of pure short
($43.6 at this concurrency) and pure long ($31.6).

So **the economics compose and the latency does not.** Mixing costs nothing in dollars per box-second and
costs the short family almost six times its tail latency. That rules out one design and points at another:
an admission rule cannot mix families on one replica by weight alone and still honour a short family's
latency floor, but it can put them on different replicas, because there is no economic penalty for
splitting work that was already additive.

## What this settles, and what it does not

Settled:

* **Admission priority is highest at short inputs and falls monotonically toward long ones.** For this box,
  $76.83 per box-hour at 60 input tokens, $67.18 at 300, $51.06 at 600, and $24 to $32 at 20,000.
* **Output length is not a selection criterion**, which removes a whole axis from the admission rule.
* **The 20,000-token corner agrees between synthetic and real documents** — $31.6 here against $28.9 on
  LongBench-v2's actual text, a 9% gap. Length is doing the work, so the surface is usable as the economic
  prior for a family once that family's own shape is known.
* **Prefix caching is not silently helping the synthetic prompts.** Both advisors flagged that identical
  padding could be reused across requests and inflate the box's side; the engine reports
  `enable_prefix_caching=False`, so it cannot be.
* **Chunk size does not fix co-residency.** Cutting the step budget from 16,384 to 2,048 — which turns a
  20,000-token prefill from two engine steps into ten, and should bound how long a short request waits
  behind it — recovers about a third of the damage (TTFT p95 5.85x becomes 3.61x) and costs the pure-short
  case its own tail (p95 0.96 s to 1.33 s). It is a placement problem, not a chunk-size problem.

Not settled:

* Where the curve turns at the short end, if it does. Density is still rising at 60 input tokens with 256
  seats, so the maximum is at or below 60 and unmeasured. Whether it is worth measuring depends on whether
  real traffic has requests that short.
* Whether 256 seats is itself the ceiling. It is the largest tried, and the 33% gain at 60 tokens says the
  seat count was binding, not that it has stopped binding.
* ~~Whether the replica split is the right answer or whether the scheduler would do it inside one
  engine~~ — measured, in `results-coresidency.md`. `long_prefill_token_threshold` cuts the co-resident
  short tail from 5.60 s to about 2.0 s; `--scheduling-policy priority` is indistinguishable from fcfs;
  `--max-num-partial-prefills` does not exist in vLLM V1. And the "free upside" hope fails: at
  saturation one long request costs about a hundred short on-time requests and the box drops from
  $54.76 to $33.75 per box-hour. What remains open is the same frontier at realistic arrival rates,
  where there is genuine slack for long work to fill.
* The latency cost of the replica split. Splitting halves each family's available concurrency, and the
  short family's density is strongly concurrency-dependent — at one request in flight the box is more
  expensive than the API. The split's loss is unmeasured.
* Everything about quality. This surface is padding, and multiplying it by a `p_i` measured on a different
  family's real text would be the same category error the long-context result already corrected once.

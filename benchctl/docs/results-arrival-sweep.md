# The box's constraint is volume, not eviction: it needs a few thousand requests an hour

> **`gemma-4` is excluded from comparisons as of 2026-08-29** — it is served only on bedrock-mantle, which this project cannot route production traffic through. Its measurements on this page are real and stay; where it was the *comparator*, see `excluded-gemma-4.md` for the restated numbers.

> The crossing point below is stated against `gemma-4` at $1.953 per 1k,
> which was the cheapest layer when this was run. Against the cheapest usable API,
> `gpt-5.6-terra` at $5.825 per 1k, the box wins from about **3,295 requests an hour** rather than
> 8,329. The sweep itself is unchanged: only the line it is compared against moved.

Measured 2026-08-29 by `benchctl/arrival_sweep.py`. Box: Qwen3.6-35B-A3B-FP8, TP=2 x 2 replicas, $15.2174/h,
prefix caching on, **through the restored conversation-affinity router** with a stable `X-Correlation-ID` per
session. Traffic: Poisson session arrivals, six turns each, 12,000-token shared preamble, ~1,500 tokens of
history added per turn, ~200 words asked back, 2 s think time between turns. 180 s per point, in-flight cap 96,
never reached.

**Every cost here has no occupancy assumption in it.** It is `hourly_usd x wall_clock / requests_completed` —
an hourly machine rate divided by what actually finished in the window. If the box is idle, the arithmetic
charges it for being idle. That is the one change that makes this run different from every other cost in this
project, and it is why the numbers move so much.

## The map

`gemma-4` on this shape costs **$1.953 per thousand requests, flat**: it has no cache and nothing to amortise,
so its price does not move with load. The box's does.

| λ (sessions/s) | requests/hour | max in flight | cached | p50 | p95 | SLO 10 s | $/1k requests | vs gemma-4 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0.02 | 313 | 1 | 88.4% | 0.31 s | 2.43 s | 100% | $48.647 | 24.9x dearer |
| 0.05 | 868 | 2 | 91.4% | 0.31 s | 2.50 s | 100% | $17.524 | 9.0x dearer |
| 0.10 | 1,574 | 3 | 92.6% | 0.31 s | 2.54 s | 100% | $9.670 | 5.0x dearer |
| 0.20 | 3,295 | 5 | 92.6% | 0.31 s | 2.71 s | 100% | $4.619 | 2.4x dearer |
| **0.40** | **8,329** | 13 | 91.5% | 0.54 s | 4.25 s | 100% | **$1.827** | **1.07x cheaper** |
| 0.60 | 12,439 | 15 | 93.8% | 0.39 s | 4.60 s | 100% | $1.223 | 1.60x cheaper |
| 0.90 | 17,889 | 21 | 93.8% | 0.44 s | 6.32 s | 100% | $0.851 | 2.30x cheaper |
| 1.30 | 23,476 | 34 | 94.3% | 0.52 s | 7.72 s | 99% | $0.648 | 3.01x cheaper |

**The crossing is at about 8,000 requests an hour.** Below it the box loses on cost no matter how well its cache
works — at 313 requests an hour it is 25x more expensive than `gemma-4` while achieving an 88% hit rate. Above
it the box improves monotonically, to 3.0x cheaper at 23,476 requests an hour, with p95 still inside a 10-second
SLO and 99% attainment.

## The expectation this run was built on was wrong

The prefix-reuse page argued the box was squeezed from two sides: it needs to be busy to amortise its hourly
rate, and busy means concurrent conversations, and concurrent conversations evict each other's prefixes. The
survival experiment had measured 99% of a prefix surviving at twelve conversations, 71% at twenty and **0% at
thirty-two**, and the break-even the box needed was 71.4%. Those two nearly touched, so the winning region
looked like it might be empty.

**It is not, and the second jaw of the vice never closes.** The hit rate *rises* with load across this whole
sweep — 88.4% at one request in flight to 94.3% at thirty-four — because more traffic against a shared preamble
means the preamble is more often already resident, not less. At the top of the sweep the box is holding 94.3%
with thirty-four requests in flight.

The reason the survival experiment found a cliff and this does not is prefix size, and it is worth stating
because it is what makes the cliff a real constraint for some traffic and not others. That experiment used
prefixes of about 60,000 tokens and higher; this traffic carries about 13,000. Thirty-four sessions of 13k
occupy a small fraction of a 2.04M-token-per-replica pool, and eviction never starts. **So the cliff is a
function of the working set, not of the concurrency**, and the constraint that binds at this prefix size is
volume.

That correction runs against the box's story in one way and for it in another. It removes the "thin margin"
framing — there is nothing thin about 3.0x — and it replaces it with a harder threshold: the box is not cheap
at all until it is carrying real traffic.

## What this means as a routing rule

The earlier rule was about token shapes, then about sessions. It now has a third term, and it is the one an
operator can act on first:

- **Do not route to the box at all unless it can be kept above a few thousand prefix-reusing requests an
  hour.** Below that the machine's hourly cost dominates everything the cache can save — at 313 requests an hour
  the box is 25x dearer than the $1.953 line and 8x dearer than the $5.825 one. This is a capacity-planning
  question, not a per-request one. The value of the threshold is whatever the cheapest routable API costs:
  **8,329 requests an hour against `gemma-4`'s $1.953, and 3,295 against `gpt-5.6-terra`'s $5.825**, which is
  the one that applies now that `gemma-4` is not routable.
- **Above that threshold, route turn 2 and later of any session whose prefix is resident.** The affinity router
  makes that the same thing as routing by `X-Correlation-ID`.
- **Watch the working set, not the concurrency.** Eviction is set by resident tokens. At 13k-token prefixes it
  never bit at 34 in flight; at 60k it bit at 32 sessions. The number to alarm on is share of the KV pool.
- **Decode-heavy traffic still goes to an API** whatever the load: the box's output rate is $4.12 per Mtok
  against `gpt-5.6-terra`'s $13.20 and `claude-haiku-4-5`'s $5.00, so on output the box is no longer the cheap
  one by a wide margin — and prefill caching does not touch output at all. (Against `gemma-4`'s $0.40 the gap was
  ten to one, which is what this line originally said.)

## What this does not say

**Two of the three constraints are still assumptions about the future.** "Can be kept above 8,000 requests an
hour" is a forecast, and so is "will still be resident". This run measures what happens at a given arrival rate;
it does not show that a router can predict one.

**The crossing point is specific to the comparison and the shape, and the comparison has already changed once.**
It is where the box's amortised cost meets whatever the cheapest routable API charges, on 13k-token prefixes with
200-word replies. At $1.953 that was 8,329 requests an hour; at $5.825 it is 3,295. A different output share moves
it, a different competitor moves it, and AWS changing a published rate moves it — so the number to carry forward
is the box's cost curve, which is measured, rather than the crossing, which is a comparison.

**180 seconds per point, one window each, no repeats.** The low-λ points rest on 18 to 48 completed requests.
Sessions still in flight when the window closes are abandoned, so their work is in the wall clock but their
requests are not in the count — which overstates the box's cost by roughly the in-flight share, about 4% at the
top of the sweep. Conservative, but it is there.

**No quality measurement on this page.** This is a bill and a latency distribution. The quality gap it named as
the next gap has since been measured in `results-prefix-fidelity.md`: instruction retention and prefix retrieval
do not degrade under caching, and the box's one defect is that it fabricates a well-formed answer where the APIs
refuse.

**The affinity router had to be restored to run this**, and it pins pod IPs, so it will go stale again the next
time a replica is rescheduled. `instruments/affinity/render.py --verify` is the check; a sweep on the affinity
path that skips it is measuring the plain Service and will not say so.

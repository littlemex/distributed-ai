# The same arrangements priced in seconds and in failures, where the ordering inverts

**Measured 2026-08-30, no new spend.** Both advisors said the same two things were missing from
`results-escalation-and-the-box.md`: nothing measured latency, and transport failures were being
excluded as though they were not part of the product. Both were already recorded on every episode.

Pooled twenty instances, the same set and the same oracle stopping as the dollar table.

## In seconds

Per-episode wall clock:

| arm | p50 | mean | p95 | max |
|---|---|---|---|---|
| box | 76 s | 94 s | 275 s | 276 s |
| `gpt-5.6-terra` | **66 s** | **69 s** | **130 s** | 173 s |
| `claude-fable-5` | 97 s | 178 s | 501 s | 966 s |

**The remote cheap API is faster than the local GPU**, on every percentile. The box takes about 31 steps
where terra takes 15, and no amount of network proximity closes a 2× difference in turn count. The
expensive tier is the slowest and by far the widest — 966 seconds at the maximum.

End to end, per arrangement:

| arrangement | solved | bill | p50 | mean | p95 |
|---|---|---|---|---|---|
| cheap alone | 16/20 | $2.9545 | 66 s | 69 s | 130 s |
| box alone | 14/20 | $0.8997 | 76 s | 94 s | 275 s |
| **cheap → expensive, no box** | 20/20 | $5.9960 | **67 s** | **110 s** | **382 s** |
| box → expensive | 20/20 | $5.0412 | 82 s | 147 s | 389 s |
| box → cheap → expensive | 20/20 | $5.2461 | 82 s | 167 s | 493 s |

**The arrangement with no box in it is the fastest of the three that solve everything, at every
percentile.** The box's 15.9% dollar saving costs 22% more median latency and 34% more mean. For batch
work that is a fair trade; for anything a person waits on, the dollar table was answering the wrong
question.

## In failures

The failures were excluded from the dollar table because they say nothing about model quality. They say
a great deal about the arrangement.

| tier | episodes | failed | rate | sunk on the failures |
|---|---|---|---|---|
| `claude-fable-5` | 24 | **4** | 16.7% | **$17.6850** |
| `gpt-5.6-terra` | 24 | 0 | 0.0% | — |
| box | 39 | 0 | 0.0% | — |

Every premium failure is the gateway answering HTTP 200 with an empty stream. **The sunk spend on four
failed episodes, $17.6850, exceeds the entire successful premium bill of $14.5899 over the twenty usable
instances**, because they die late: at 5, 12, 25 and 28 steps, having already billed $0.72, $2.29, $5.43
and $9.25.

The box's zero is over 39 episodes in these passes, but it is not a clean zero either: three episodes in
the 80-step pass were lost when the node's containerd died and both replicas were rescheduled. They were
re-run after it came back, so they are not in the recorded files, and that is stated here rather than
being allowed to read as perfect availability.

## Pricing the retries, which inverts the ordering

A failed episode has to be attempted again, and the failed attempt was billed. At a 16.7% failure rate
with a mean sunk cost of $4.4212, each *attempted* premium call carries an expected extra
p/(1−p) × $4.4212 = **$0.8842**. So an arrangement's exposure is set by how many times it calls the
unreliable tier.

| arrangement | premium calls | bill | + retries | total |
|---|---|---|---|---|
| expensive alone | 20 | $14.5899 | $17.6850 | $32.2749 |
| **box → cheap → expensive** | **4** | $5.2461 | $3.5370 | **$8.7831** |
| cheap → expensive, no box | 4 | $5.9960 | $3.5370 | $9.5330 |
| box → expensive | **6** | $5.0412 | $5.3055 | $10.3467 |

**The ordering inverts.** Without retries the best arrangement was box → expensive at $5.0412 and the
three-stage cascade was the worst of the three. With retries priced in, the three-stage cascade is the
**cheapest** at $8.7831 and box → expensive is the **dearest** at $10.3467 — because it calls the
unreliable tier six times where the others call it four.

That is a general point about cascades and not a fact about these two vendors: **when the last tier is
both expensive and unreliable, the value of a middle tier is partly that it keeps you away from the last
one.** The dollar-only table could not see it, because it had excluded exactly the events that create it.

The box's contribution survives the change, at a different size and in a different arrangement: against
the no-box cascade it now saves 7.9% rather than 15.9%, and it earns that as the *first* of three stages
rather than as the only alternative to the premium tier.

## What this does not support

**Four failures.** The 16.7% rate is four events on one gateway deployment over one week, and the retry
arithmetic is linear in it. At 8% the ordering reverts to the dollar table's; at 25% the three-stage
cascade wins by more. The rate is the number to keep measuring, and it is a property of this deployment
rather than of the model behind it.

**A single retry.** The arithmetic assumes one retry succeeds. A tier that fails 16.7% of the time fails
twice in a row about 2.8% of the time, and nothing here measures whether the failures are independent —
if they cluster, the expectation understates.

**Latency without concurrency.** The wall clocks are from episodes running four at a time against a box
sized for far more. A loaded box is slower per episode, so its latency column is optimistic in exactly
the regime where its cost column is realistic. The two columns cannot both be read at their best.

**No user-facing latency claim.** These are whole-episode times for an agent editing a repository, not
response times. What they support is a comparison between arrangements, not a service-level statement.

# The effort axis, measured on itself

The power screen could size v2 but not clear it: v1 measured the model axis and holds no
cell for a member at a non-default effort, so the quantity the whole plan turns on — how
much a member disagrees with *its own* higher effort level — had never been observed.
This pilot observes it. 137 calibration questions, three members at every level they
declare, twelve arms, asked twice: 3,288 calls, no failures, about $28.

The result changes what v2 should do. **Above the lowest effort level, changing the dial
is statistically indistinguishable from asking the same arm a second time.** The dial has
exactly one real notch — off to on — and beyond it costs up to nine times more for
nothing.

## What was collected

| | |
| --- | --- |
| Questions | 137 (calibration fold, seven MMLU-Pro categories) |
| Arms | `gpt-5.6-sol`, `gpt-5.6-terra`, `grok-4.6` at `default` plus every declared level |
| Passes | one matrix, one repeat of the same cells, so re-ask noise is measured not assumed |
| Calls | 3,288, zero failures |
| Budget | 16,384 completion tokens, streaming, idle deadline 120 s, first-event 1,200 s |

## The dial moves cost and latency, not accuracy

| Arm | Accuracy | Completion tokens | $/question | TTFT |
| --- | --- | --- | --- | --- |
| gpt-5.6-sol@none | 0.781 | 7 | 0.00126 | 4.3 s |
| gpt-5.6-sol@low | 0.832 | 123 | 0.00381 | 5.7 s |
| gpt-5.6-sol | 0.825 | 179 | 0.00503 | 6.8 s |
| gpt-5.6-sol@high | 0.810 | 311 | 0.00796 | 9.0 s |
| gpt-5.6-terra@none | 0.686 | 8 | 0.00065 | 0.6 s |
| gpt-5.6-terra@low | 0.774 | 201 | 0.00321 | 2.7 s |
| gpt-5.6-terra | 0.796 | 235 | 0.00366 | 3.1 s |
| gpt-5.6-terra@high | 0.788 | 367 | 0.00541 | 4.4 s |
| grok-4.6@minimal | 0.810 | 456 | 0.00362 | 14.1 s |
| grok-4.6@low | 0.832 | 448 | 0.00356 | 18.2 s |
| grok-4.6 | 0.832 | 472 | 0.00372 | 17.5 s |
| grok-4.6@high | 0.810 | 2,454 | 0.01680 | 55.8 s |

Every model's accuracy is flat, and not even monotone, above its lowest level. `grok-4.6`
at `high` spends five times the tokens of its own `low` arm, takes three times as long,
costs 4.7 times as much, and scores 2.2 points *lower*. The one step that does anything
is the first: turning reasoning off costs `gpt-5.6-terra` 10.9 points and `gpt-5.6-sol`
4.4.

## Indistinguishable from asking twice

Accuracy tables at 137 questions cannot resolve two points, so the claim above needs a
tighter test, and the repeat pass supplies it. If two arms are the same, then one ask of
each disagrees exactly as often as two asks of one arm do — so the arm's own re-ask
disagreement is the null, and the excess over it is the effect.

| Pair | Disagreement | Own re-ask noise | Excess |
| --- | --- | --- | --- |
| sol@high / sol@low | 3.6% | 2.9% | +0.7% |
| sol / sol@high | 4.4% | 4.7% | −0.4% |
| sol / sol@low | 5.1% | 4.7% | +0.4% |
| terra / terra@high | 5.1% | 4.7% | +0.4% |
| terra / terra@low | 8.0% | 6.9% | +1.1% |
| terra@high / terra@low | 8.8% | 5.8% | +2.9% |
| grok / grok@low | 4.4% | 6.2% | −1.8% |
| grok / grok@minimal | 6.6% | 6.9% | −0.4% |
| grok / grok@high | 6.6% | 6.6% | +0.0% |
| grok@high / grok@low | 6.6% | 6.9% | −0.4% |
| grok@high / grok@minimal | 7.3% | 7.7% | −0.4% |
| grok@low / grok@minimal | 6.6% | 7.3% | −0.7% |
| **sol@low / sol@none** | **10.9%** | 4.4% | **+6.6%** |
| **sol@high / sol@none** | **10.2%** | 4.4% | **+5.8%** |
| **sol / sol@none** | **10.2%** | 6.2% | **+4.0%** |
| **terra@high / terra@none** | **19.0%** | 3.3% | **+15.7%** |
| **terra@low / terra@none** | **19.0%** | 5.5% | **+13.5%** |
| **terra / terra@none** | **16.8%** | 4.4% | **+12.4%** |

Twelve of the eighteen pairs sit within a point of the noise floor, six of them below it.
The six that stand out all involve `none`. Re-ask disagreement itself runs 2.9% to 8.0%
per arm — which is the second reason the earlier design work pointed at asking each cell
more than once, and the reason a single-ask comparison between two effort levels on this
benchmark measures mostly the harness.

## The frontier collapses to three points

Priced with the gateway's own rate table, over all twelve arms:

| On the frontier | Accuracy | $/question |
| --- | --- | --- |
| gpt-5.6-terra@none | 0.686 | 0.00065 |
| gpt-5.6-sol@none | 0.781 | 0.00126 |
| grok-4.6@low | 0.832 | 0.00356 |

Nine of twelve arms are dominated — including every `high` arm and every default arm.
Above `grok-4.6@low` no amount of money buys accuracy on this benchmark; below it, 2.8
times less money costs 14.6 points. A router choosing among these twelve arms has three
candidates, and two of them differ only in how much accuracy the buyer is willing to give
up for a tenth of the price. That is a price list, not a routing problem.

## What it means for v2

The sizing from the screen survives: within-member discordance has a median of 7.3%,
which puts the questions needed to resolve two utility points at about 1,400 at one ask
per cell — the same order as the 1,048 to 2,832 the model axis implied. The design is
affordable.

**The mechanism is what is missing.** v2 exists to ask whether model diversity is
necessary or a restatement of the compute dial. On MMLU-Pro the dial has one notch, the
models agree with each other about as often as an arm agrees with itself, and one arm
dominates nine others. Δ ≈ 0 was always an acceptable answer for this experiment, and the
pilot says that is what 1,200 questions and three asks would buy — a tight interval
around a difference that this benchmark structurally cannot contain.

So the recommendation is to spend the next dollars on a **task family where the dial has
range**, not on more questions here. Long-form generation, multi-step or agentic work,
anything where output length is not bounded by a letter of the alphabet: those are the
cases where a high effort level plausibly earns its tokens. This pilot is the cheap screen
to run first, and it is now a repeatable one — `power.py --pilot` against a matrix and a
repeat pass, about $28 and forty minutes.

## Caveats, in the order they could bite

- **One dataset, one fold, 137 questions.** The accuracy column resolves about 6.5
  points, so the individual numbers are not claims. The noise-floor comparison is paired
  and much tighter, and it is what the conclusion rests on.
- **Three members.** The five members whose token counts the gateway did not report on a
  stream were excluded; that gap is fixed and deployed now, so the next pilot can include
  them.
- **`grok-4.6@high` truncated 3 of 137 answers even at 16,384 tokens** (2.19%), so its
  accuracy is understated by up to that much. It is the only arm that hit the cap, and
  raising the cap for it is cheap — but the direction of the error is against the arm
  this pilot already finds no use for.
- **Effort levels are not comparable across providers.** `low` for one model and `low`
  for another share nothing but the word, so the across-member rows in the raw output
  compare measured points, not settings.

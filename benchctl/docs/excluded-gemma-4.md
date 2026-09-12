# gemma-4 is excluded from comparisons, and what that moves

Decided 2026-08-29, on a procurement constraint rather than a measurement: `gemma-4` is served **only** on
bedrock-mantle's OpenAI-compatible path — the gateway's own registry says so in as many words — and that path is
a bottleneck this project cannot route production traffic through. A layer that cannot receive the traffic is not
a routing option, however it scores.

**Its measurements stay.** `gemma-4` was really measured on OCRBench, on long-document summarisation, on the
cache-eligibility probes and on the prefix-fidelity runs, and those numbers are true. Deleting them would
falsify the record, and two of them are load-bearing for conclusions that have nothing to do with `gemma-4`
being usable:

- It is the only layer measured whose published price carries **no cache-read rate at all**, which corroborates
  the separate finding that it returns no cached tokens on this gateway in any request shape.
- Its price was the subject of the 36x error in `routing-table.md`, and that story is about where a price comes
  from rather than about the model.

What changes is every place `gemma-4` was the **comparator**, because the box was being measured against the
cheapest layer available and that is now someone else.

## The two headline numbers move in the box's favour

On the prefix-reuse shape (13,338 prompt tokens, 213 output, per request):

| layer | measured hit rate | $/1k requests | box against it |
| --- | --- | --- | --- |
| **box-qwen36-tp2x2** | 82.5% | **$1.635** | |
| ~~api-gemma-4~~ | 3.1% | ~~$1.953~~ | ~~1.20x cheaper~~ |
| **api-gpt-5.6-terra** | 99.7% | **$5.825** | **3.56x cheaper** |
| api-sonnet-5 | 99.8% | $7.268 | 4.44x cheaper |
| api-haiku-4-5 | 0.0% | $14.403 | 8.81x cheaper |

So the box is **3.6x cheaper than the cheapest usable API on this traffic, not 1.20x**, and the arrival sweep's
crossing point drops with it:

| the bar the box has to clear | box wins from |
| --- | --- |
| ~~gemma-4 at $1.953/1k~~ | ~~about 8,329 requests/hour~~ |
| **gpt-5.6-terra at $5.825/1k** | **about 3,295 requests/hour** |

That is a 2.5x easier threshold, and it is worth being explicit that this is not a new measurement: the sweep is
unchanged and only the line it is compared against moved. The box's cost at each arrival rate is exactly what it
was.

## The frontiers change, and gemma-4 was hiding two layers

Recomputed from the same per-item verdicts with `gemma-4` dropped:

**ocrbench-stratified-278**, on the 195 items every layer answered:

| layer | rate | $/1k items | p50 | frontier |
| --- | --- | --- | --- | --- |
| api-sonnet-5 | 0.980 | $1.047 | 2.61 s | **yes** |
| api-opus-5 | 0.974 | $7.733 | 1.99 s | **yes** — was dominated by gemma-4 |
| api-gpt-5.6-sol | 0.949 | $3.128 | 2.20 s | **yes** — was dominated by gemma-4 |
| box-qwen36-tp2x2 | 0.923 | **$0.117** | **0.11 s** | **yes** |
| api-gpt-5.6-terra | 0.923 | $1.559 | 1.77 s | no — dominated by the box |
| api-grok-4.6 | 0.949 | $1.820 | 8.64 s | no — dominated by sonnet-5 |
| api-haiku-4-5 | 0.810 | $0.311 | 1.26 s | no — dominated by the box |
| api-gpt-5.5 | 0.959 | unpriced | 1.90 s | not placed |

**govreport-stratified-80**, on all 80:

| layer | rate | $/1k items | p50 | frontier |
| --- | --- | --- | --- | --- |
| **box-qwen36-tp2x2** | **0.812** | **$4.505** | 5.28 s | **yes, alone** |
| api-sonnet-5 | 0.800 | $58.313 | 10.55 s | no — dominated by the box |
| api-haiku-4-5 | 0.725 | $13.109 | 7.38 s | no — dominated by the box |

The summarisation frontier collapses to the box by itself. On OCRBench the frontier gets *wider* rather than
narrower, which is the interesting direction: `gemma-4` had been dominating `claude-opus-5` and `gpt-5.6-sol`,
and removing it does not promote the box — it promotes them.

## What does not change

- **The agentic per-solved-task result.** Its comparator was `gpt-5.6-terra`, not `gemma-4`, so the box at 2.61x
  dearer with its cache off and 0.78x with it on stands unaltered.
- **Every cache-eligibility finding.** The turn-boundary result, the zero-cache result for `claude-haiku-4-5`,
  the 1.60x tokeniser ratio on the Claude premium pair — none of those depend on `gemma-4` being routable.
- **The verifier decision.** Its arithmetic used `gemma-4`'s $1.953 as the bar, which was the *hardest* bar
  available; against a $5.825 bar the escalation policy survives an even higher unanswerable rate, so the
  conclusion that the arithmetic does not kill the idea only gets stronger. The two kills that did fire — the
  extractor's 0-to-307 false flags and the density slope — have nothing to do with which API it was compared to.
- **The rule's shape.** Prefill-heavy with prefix reuse to the box, single-shot and decode-heavy to an API, and
  a volume threshold before the box is worth using at all. Only the threshold's value and the API's name move.

# Cost per solved task when every tier is driven through its own tool-calling interface

**Measured 2026-08-29.** Fifteen SWE-bench Verified instances, one policy per arm so a single model
drives the whole episode, 40 steps and 1.2M tokens per episode, `--protocol function-calling`.
`docs/PROTOCOL.md` explains why this arm exists and what it is not.

The instances were fixed before any of this ran, by a rule stated in advance: the first instance of each
repository family in `pilot-subset.json`, plus the second for every family with three or more.

## Headline

On the twelve instances where every arm ran to an end its own policy chose:

| arm | solved | steps / episode | spend | per solved task |
|---|---|---|---|---|
| box `Qwen3.6-35B-A3B-FP8` | 6 / 12 | 30.8 | $0.5714 | **$0.0952** |
| `gpt-5.6-terra`, reasoning `high` | 8 / 12 | 14.9 | $1.9911 | $0.2489 |
| `claude-fable-5` | **12 / 12** | 13.5 | $8.1485 | $0.6790 |

**Capability is strictly nested and cost runs the other way.** Every instance the box solved, terra
solved; every instance terra solved, fable solved; and fable solved all twelve. Meanwhile the box costs
2.61× less per solved task than terra and 7.13× less than fable.

Only the box-versus-fable gap is statistically distinguishable — six discordant pairs, exact two-sided
p = 0.031. Box against terra rests on two, p = 0.500, so on these instances the two are not separable on
solve count and the difference between them is the price.

## Why twelve and not fifteen

Three episodes on the premium tier ended with the gateway answering 200 and an empty stream:
`django-15128`, `matplotlib-26208`, `pylint-4551`. All three produced no diff, so they are transport
failures rather than evidence about `claude-fable-5`, and they are dropped from the paired set rather
than scored as misses. Counted over all fifteen, fable reads 12/15, box 6/15 and terra 9/15 — the same
ordering, with fable's quality understated by an infrastructure fault.

## What this corrects, and what it restores

`docs/results-agentic-cost-per-solve.md` said two things about the box against `gpt-5.6-terra`:

1. **the box costs 2.61× more per solved task.** Wrong, and wrong by almost exactly the reciprocal: the
   box costs 2.61× *less*. That figure came from a text-protocol run on which the box loses 42% of its
   actions to serialisation (`PROTOCOL.md`), so it was pricing a grammar.
2. **the box solved nothing the API did not.** Right, and it survives every change made here. Under
   function calling with reasoning intact, the box's solve set is still a strict subset of terra's, which
   is in turn a strict subset of fable's.

So the shape of the routing question is unchanged and its arithmetic is inverted. The box is not a
cheaper way to get the same work done; it is a cheaper way to get *some* of the work done, and the price
of the work it can finish is a quarter of the cheap API's.

An earlier draft of this page reported the box's solve set as a strict *superset* of terra's. That was
measured against a terra forced to run with reasoning off, which is the next section.

## The comparator had to be fixed before it could be compared

This gateway's `/v1/chat/completions` refuses function tools together with any `reasoning_effort` other
than `none`. Run that way, terra is a different model: reasoning falls from 80% of its output tokens to
zero, **26% of its steps produce no tool call at all** — it answers in prose where it should call a tool —
and it solves 5 of 15 instead of 9.

| terra under function calling | solved | unusable actions | reasoning share of output | spend |
|---|---|---|---|---|
| `/v1/chat/completions`, `effort=none` | 5 / 15 | 67 (26.2%) | 0.0% | $1.1955 |
| `/openai/v1/responses`, `effort=high` | 9 / 15 | 0 (0.0%) | 80.0% | $3.1903 |

The harness therefore speaks both wires. `tiers.function-calling.json` marks the tier `"api":
"responses"`, `run.sh` derives the path, and `transport.py` translates the loop's single chat-shaped
message list into Responses items at the boundary — an assistant tool call becomes a `function_call`
item and its result a `function_call_output` item with the same `call_id`. The model's own `reasoning`
items are not echoed back; the gateway accepts the history without them, and carrying encrypted
reasoning across turns would put content in the prompt that the token accounting cannot see.

One incidental note for anyone following the error message: chat completions tells you to use
`/v1/responses`, and this gateway serves it at `/openai/v1/responses`. The bare path is a 404.

## What the numbers do not support

**Twelve instances.** The nesting is a statement about these twelve, not a probability claim, and only
one of the three pairwise gaps clears p < 0.05.

**The box's per-solve cost assumes the box is busy.** $0.0952 uses the marginal token rate measured on
this deployment, and `benchctl/docs/results-arrival-sweep.md` shows that rate only obtains above roughly
3,295 prefix-reusing requests an hour. A box idling between episodes bills $15.2174/h regardless; at
pilot volumes that dominates every figure here. This is a marginal cost, not an invoice.

**The box is the only arm the step budget binds.** It used 30.8 steps an episode against 15 and 14, and
six of its fifteen episodes ended on the 40-step ceiling with a diff that did not pass. Terra ended all
fifteen on its own. Raising the ceiling would change the box's number and nothing else's, so the 6/12 is
a result at this budget rather than a property of the model.

**Cache hit rates differ and were not equalised.** 87.0% of the box's prompt tokens were cached reads,
91.2% of terra's and 78.5% of fable's. All three are priced at each tier's own cached rate, so the
comparison is of what each actually cost rather than of a like-for-like cache state.

## Reproducing

```bash
export KUBE_CONTEXT=distai-eks NAMESPACE=swe-pilot
export STRATOCLAVE_HOST=<gateway host> STRATOCLAVE_DEFAULTS=<gateway repo>/backend/mvp/defaults
export STRATOCLAVE_API_KEY=<token>
export QWEN_LOCAL_ENDPOINT_URL=http://qwen-serving.qwen-trial.svc.cluster.local:8000/v1/chat/completions
export SUBSET=<the fifteen> PROTOCOL=function-calling
export TIERS=$PWD/tiers.function-calling.json

PASS=fc  POLICIES=self-hosted-always ./sweep.sh
PASS=fc  POLICIES=premium-always ./sweep.sh
PASS=fcr POLICIES=cheap-always ./sweep.sh    # terra on the Responses wire, reasoning high
```

Three operational notes. The instance images are 1-3 GB against a node's 20 GiB, so `run.sh` declares an
`ephemeral-storage` request — without it the kubelet reached DiskPressure and evicted a running episode
mid-pull, twice, on the same node. `sweep.sh` runs under `set -e` and waits on the results volume through
`kubectl exec`, so one reset connection kills a whole pass; the pass is resumable, so wrap it in a retry
rather than making that wait loop tolerant. And the gateway's personal credit is denominated in tokens:
reasoning at `high` cost about 0.8M tokens an episode, so a fifteen-instance pass on that tier needs
roughly 12M of credit.

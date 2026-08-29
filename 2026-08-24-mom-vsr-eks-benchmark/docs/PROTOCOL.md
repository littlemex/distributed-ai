# How a model is asked for a tool call, and what that choice was costing one tier

**Status as of 2026-08-29.** This page exists because a self-hosted `Qwen3.6-35B-A3B-FP8` scored zero on
every episode, and the zero turned out to be about serialisation rather than about software engineering.
It records the harness's grammar, the version it is frozen at, and the measurement that separates *can the
model drive the tools* from *can the model fix the bug*.

## The two protocols

The benchmark's protocol is text. The system prompt asks for exactly one

```
<action tool="search">
pattern: def prepare_body
</action>
```

and the reader takes the `key: value` lines inside the block. It is text rather than the provider
function-calling API for a reason that still holds: the byte sequence is identical for every tier, it is
inspectable, and it is versioned here rather than in a vendor's stack.

Alongside it there is a second, **diagnostic** arm, `--protocol function-calling`, which declares the same
tools as JSON schemas and reads `tool_calls`. It is not a scored arm of the benchmark. It exists to answer
one question the text arm cannot ask itself: how much of a model's failure to drive the tools is the text
protocol resembling, without matching, the tool-call syntax the model was trained on.

## Grammar v1 and v2

**v1** accepted `key: value` lines and the `key: <<<heredoc>>>` form, and nothing else.

**v2** additionally accepts two encodings of the same key/value pair inside the block:

```
<parameter=pattern>
qdp
</parameter>
```

and `<key>value</key>`, the latter only for a name the tool actually owns — so `<dir>` is an argument to
`list_dir` and `<thinking>` is never an argument to anything.

Across all four encodings one rule holds: **the first non-empty value for a name wins, and nothing is ever
synthesised.** v2 therefore does not

- invent a value for a name written with nothing after it,
- map an invented tool name onto a real one,
- or repair malformed JSON in a function call.

Every action records which encodings read it, and every episode reports how many of its actions needed one
v1 would have refused (`format_compliance.tolerant_parse`).

### v2 was written after watching one tier fail, and that is disclosed rather than dressed up

The change is tier-agnostic in code and it is not neutral in motivation. Counting the recorded steps of
every tier, the actions whose tool parsed but whose target argument was never named:

| tier | steps | argless | no action at all |
|---|---|---|---|
| `gpt-5.6-terra` | 1330 | 0 (0.0%) | 14 |
| `claude-fable-5` | 258 | 0 (0.0%) | 5 |
| `Qwen3.8-27B` (the previous box) | 640 | 8 (1.2%) | 4 |
| **`Qwen3.6-35B-A3B`** | **320** | **220 (68.8%)** | **74** |

So v2 cannot change what the two APIs scored, and it lifts exactly one tier — the one under test. The
defence is not that the change is neutral. It is that the grammar is **frozen at v2**, specified before the
re-run, and never extended per-model again; that the residual failures stay charged to the model; and that
the tolerant-path count is reported next to every result rather than in a footnote.

The failures v2 does **not** absorb, all of them observed from this model:

- `<parameter=pattern">` — the native form with the wrapper's attribute quoting bleeding in.
- `</path>` closing a block opened by `<action tool="read_file">`, i.e. closing with the argument's name.
- Two invented tools, `run_command` and `run`.
- `pattern:` with nothing after it.

Three distinct serialisation slips is where extending the reader stops being a fix and starts being a
parser for one model. The grammar stayed at v2 and the function-calling arm was built instead.

## What the protocol was worth, measured

Fifteen instances, chosen before any of this was run by a rule stated in advance — the first instance of
each repository family in the pilot subset, plus the second for every family with three or more. One
policy, `self-hosted-always`, so the box drives the whole episode. Same box, same instances, same step and
token budgets; only the protocol differs.

| | text, grammar v1 | text, grammar v2 | function calling |
|---|---|---|---|
| solved | 0 / 8 | 3 / 15 | **6 / 15** |
| produced any diff | 0 / 8 | 6 / 15 | **13 / 15** |
| unusable actions | 68.8% argless | **45.2%** | **1.0%** |
| — of which no action at all | 23% of steps | 180 steps (35.2%) | 1 step |
| — invented a tool | 2 | 6 | 0 |
| — named no target | 220 | 45 | 4 |
| steps | 320 | 511 | 490 |
| spend | $0.124 | $0.4697 | $0.7505 |

The v1 column is the aborted run and covers 8 instances, so read it as the direction and not as a paired
number. The v2 and function-calling columns are the same fifteen instances.

Two things in that table matter more than the solve counts.

**The function-calling arm's solves are a superset.** Three instances were solved under function calling and
not under the text protocol (`django-11880`, `pylint-6386`, `pytest-7432`); none went the other way. The
text protocol was not trading one kind of success for another, it was removing successes.

**All three of the text arm's solves needed the tolerant path** (10, 11 and 8 actions respectively). Under
the frozen v1 grammar this box solves nothing on these fifteen instances, and that is the number the
earlier agentic comparison was built on.

## What this invalidates

`docs/results-agentic-cost-per-solve.md` prices a solved task on the box against the APIs. Its box column
came from a text-protocol run, on which this box loses 45% of its actions to serialisation and the two APIs
lose none. That comparison is therefore measuring a protocol mismatch and reporting it as capability, and
its box figure is a lower bound on the box rather than an estimate of it.

Restating it needs the API tiers under function calling too, on the same instances. That is in progress and
has one hard obstacle: `gpt-5.6-terra`, the cost comparator, cannot combine function tools with
`reasoning_effort` on this gateway's `/v1/chat/completions` — it requires `reasoning_effort: "none"` or the
`/v1/responses` endpoint. Running it with reasoning switched off makes it a different comparator, so that
arm will be reported with the change stated rather than folded in. `claude-fable-5` needs no such change.

## What is not claimed

That function calling is the better protocol in general. It replaces one visible, versioned, identical-for-
every-tier encoding with a different vendor-specific adapter per tier — vLLM's `qwen3_coder` parser here,
each provider's own stack elsewhere — so an arm built on it compares *model plus adapter*, and the adapters
are neither identical nor equally good. What the measurement above establishes is narrower and enough: for
this model, on this corpus, the text protocol costs half its solves and 44 of every hundred actions, and a
benchmark that reports one number cannot tell you that.

That a hand-rolled protocol can be made neutral. It cannot. Any syntax resembles some model's training
distribution more than another's, and this one is a near-miss of the very format `Qwen3.6-35B-A3B` was
trained to emit — near enough that the model mixes the two. The available fix is not a better syntax, it is
reporting format compliance and task success as two numbers, which `format_compliance` in every
`episode.json` now does.

## Reproducing

```bash
export KUBE_CONTEXT=distai-eks NAMESPACE=swe-pilot
export STRATOCLAVE_HOST=<gateway host> STRATOCLAVE_DEFAULTS=<gateway repo>/backend/mvp/defaults
export STRATOCLAVE_API_KEY=<token>
export QWEN_LOCAL_ENDPOINT_URL=http://qwen-serving.qwen-trial.svc.cluster.local:8000/v1/chat/completions

# the text arm, written one level deeper so it cannot land on an earlier pass
SUBSET=canary-subset.json POLICIES=self-hosted-always PASS=2 ./sweep.sh

# the diagnostic arm; PASS must differ because the protocol is part of what an episode is
SUBSET=canary-subset.json POLICIES=self-hosted-always PASS=fc PROTOCOL=function-calling ./sweep.sh
```

Every episode records `format_compliance.protocol` and `format_compliance.grammar_version`, and every
episode directory now holds `transcript.json` — the assistant turns in full, so a later grammar change can
be re-read against what was actually sent instead of re-run. The absence of that file is why the 2228
already-paid-for steps above could only be counted by their signatures.

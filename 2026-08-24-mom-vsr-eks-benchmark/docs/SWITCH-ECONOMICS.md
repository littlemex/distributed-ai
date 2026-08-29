# What switching models mid-session costs

Before spending anything on an agentic experiment, one question is answerable from the
rate table alone: can "run a cheap model and call the expensive one at the important
moments" be cheaper than using the expensive model throughout? The answer decides whether
there is an experiment at all, and it is not the obvious yes.

`bench/switch_economics.py` computes it from the gateway's own `pricing.json`, so the
prices are the ones that get billed.

## Why a switch costs anything

In a long agentic session almost every input token is a prefix-cache hit — the
SemiAnalysis AgentX measurement on real Claude Code traces puts it above 95% — and a
cache hit is an order of magnitude cheaper than a fresh token. The gateway's table prices
this explicitly: for `fable`, fresh input is $10.00 per million tokens and a cache read is
$1.00.

Two consequences pull in opposite directions.

**The baseline is much stronger than its list price.** A premium model that has been
running since the first turn reads its own cached prefix at a tenth of list. Comparing
list prices across models overstates what switching can save.

**A model being escalated to has no cache.** It has never seen the conversation, so it
pays the fresh price on everything accumulated to that point — once, at the moment of the
switch. That is the switch tax, and it grows with how late the escalation happens.

## The numbers

A 60-step session, context growing 3,000 tokens a turn from 20,000 to 197,000, 500 output
tokens a turn. Baseline `fable` throughout, cheap arm `gpt-5.6-terra`:

| | Cost | Against the baseline |
| --- | --- | --- |
| `fable` for all 60 steps | $9.81 | — |
| `gpt-5.6-terra` for all 60 steps | $2.22 | 77% less, quality unknown |
| cheap, then one escalation at the best point | $4.69 | 52% less |
| the switch tax at the midpoint | $1.34 | = 8.3 warm premium steps |

**One escalation pays for itself after about nine cheap steps**, and that threshold is
stable across session lengths — 9 steps at 20 turns, 9 at 60, 9 at 200 — because the tax
and the per-step saving both scale with the context. Any session long enough to matter
clears it easily.

## The finding that changes the design

Cost is monotone in how late the switch happens: the best switch point is always the last
step. So **cost alone always prefers escalating later, and quality is the only thing that
argues for escalating sooner.** The experiment's whole value lies in that trade-off, which
is a real curve and not an empty region.

But the naive reading of "call the expensive model at the important moments" — spot-call
it for a step or two, then go back to cheap — loses outright, because each spot call pays
the accumulated context again:

| Spot escalations in a 60-step session | Cost | Against `fable` throughout |
| --- | --- | --- |
| 1 | $3.63 | 63% less |
| 2 | $4.99 | 49% less |
| 4 | $7.70 | 22% less |
| 8 | $13.01 | **33% more** |

At eight spot calls it is cheaper to have used the premium model for the entire session.
The requirement — do not pay premium prices all the time — therefore has exactly one
affordable implementation shape:

**Escalate once, and stay escalated.** A trigger that can fire repeatedly needs a cap, and
a policy that escalates and returns is paying the tax twice per round trip.

One corollary worth building on: the tax is proportional to the context at the moment of
the switch, so **escalating immediately after a context compaction is far cheaper than
escalating just before one**. Any harness that summarises or compacts creates natural
cheap escalation points, and a trigger that can wait for one should.

## Verified, and two things had to be fixed first

The premise is now measured rather than assumed (`bench/cache_probe.py`, raw rows in
`bench/results/cache-probe-final.json`). A 10,000-token conversation through the router:

| Call | Prompt tokens | Served from cache |
| --- | --- | --- |
| `claude-opus-5`, first sight | 9,984 | 0 |
| `claude-opus-5`, same prompt again | 9,984 | 9,982 |
| the same prompt handed to `claude-sonnet-5` | 9,984 | 0 |

The last row is the switch tax, measured: a prefix cached by one model is worth nothing to
another. Cross-region inference profiles are not the obstacle — every model above is a
`us.` profile.

Two gateway defects stood in the way and are now fixed and deployed. The Converse path
never sent a cache breakpoint, so Claude models were billed fresh for the whole history
every turn while OpenAI-protocol models were cached by their provider unasked — an
artefact that inflated the apparent premium-to-cheap cost ratio from 4.4x to 30x. And once
caching was on, Bedrock reports cached input *outside* `inputTokens`, so a cached
ten-thousand-token turn arrived as two prompt tokens and looked nearly free; the usage
block now carries the split.

## What this does not settle

- **The tax is priced as a cache write** ($12.50 per million for `fable`), which is the
  expensive reading. If a switch pays only fresh input ($10.00), the tax is a fifth
  smaller. The ordering of every conclusion above is unchanged.
- **The session model is stated, not fitted.** Linear context growth, one fixed output
  length, no compaction. The AgentX traces are the right source for real distributions and
  the pilot should replace these parameters with measured ones.
- **The tax is a property of handing over the main thread, not of using a cheap model.**
  A side task issued with its own small context — search a file, summarise a diff, read a
  test — carries no accumulated prefix and therefore pays no tax at all. Everything above
  concerns the main conversation. `V3-PLAN.md` treats the two as separate mechanisms
  because their economics have nothing in common.

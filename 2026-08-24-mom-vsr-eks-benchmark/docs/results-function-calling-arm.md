# Cost per solved task when every tier is driven through function calling

**Measured 2026-08-29.** Fifteen SWE-bench Verified instances, one policy per arm so a single model
drives the whole episode, 40 steps and 1.2M tokens per episode, `--protocol function-calling`.
`docs/PROTOCOL.md` explains why this arm exists and what it is not.

The instances were fixed before any of this ran, by a rule stated in advance: the first instance of each
repository family in `pilot-subset.json`, plus the second for every family with three or more.

## The table

| arm | solved | wrote a diff | steps | unusable actions | in | out | spend | per solved task |
|---|---|---|---|---|---|---|---|---|
| box `Qwen3.6-35B-A3B-FP8` | 6 / 15 | 13 / 15 | 490 | 5 (1.0%) | 9.90 Mtok | 69.4 ktok | $0.7505 | **$0.1251** |
| `gpt-5.6-terra`, reasoning off | 5 / 15 | 14 / 15 | 256 | 69 (27.0%) | 2.41 Mtok | 13.4 ktok | $1.1955 | $0.2391 |
| `claude-fable-5` | 12 / 15 | 12 / 15 | 201 | 1 (0.5%) | 2.90 Mtok | 117.9 ktok | $16.5883 | $1.3824 |

Box tokens are priced at the rate measured on this deployment ($0.236 fresh in, $0.0188 cache read,
$4.12 out per Mtok; `tiers.function-calling.json` carries the basis). The API tiers are priced from the
AWS Price List figures the gateway resolves.

## What this changes

`docs/results-agentic-cost-per-solve.md` reported the box at **2.61× `gpt-5.6-terra` per solved task**, and
reported that the box's successes were a strict subset of the API's — no instance the box solved and the
API did not. Both of those were artefacts of the text protocol, on which this box loses 45% of its actions
to serialisation and the APIs lose almost none.

Driven through function calling instead, on the same instances:

- The box solves **more** than reasoning-off terra, 6 against 5, and its solve set is a **strict superset**:
  it solved `pylint-6386`, which terra did not, and terra solved nothing the box did not.
- Per solved task the box is **1.91× cheaper** than that terra, not 2.61× more expensive.
- The box needs 32 steps an episode where the APIs need 13-15, which is the trajectory-length finding from
  the earlier work and it survives the protocol change.

The direction of the earlier headline was wrong. Its magnitude was measuring a grammar.

## What the numbers do not support

**This is not `gpt-5.6-terra` at its best.** This gateway's `/v1/chat/completions` refuses function tools
together with any `reasoning_effort` other than `none`, so the terra arm ran with reasoning off, where the
text arm ran it at `high` and 63.3% of its output tokens were reasoning. Two consequences, both visible in
the table: it is much cheaper per episode, and **27% of its steps produced no tool call at all** — with
reasoning off it answers in prose where it should call a tool. A like-for-like terra under function calling
needs the `/v1/responses` endpoint, which this harness does not speak. Until that exists, read the
box-versus-terra row as *the box beats a reasoning-off terra*, not as *the box beats terra*.

**The solve-count difference is not statistically distinguishable.** Box over terra rests on one discordant
pair out of fifteen; the exact two-sided paired test gives p = 1.000. What the fifteen instances do support
is the cost ratio, which is driven by token prices and trajectory lengths rather than by that one instance,
and the superset relation, which is a statement about these fifteen and not a probability claim.

**The box's per-solve cost assumes the box is busy.** $0.1251 uses the measured marginal token rate, and
`docs/results-arrival-sweep.md` shows that rate only obtains above roughly 3,295 prefix-reusing requests an
hour. A box idling between episodes bills $15.2174/h regardless, and at pilot volumes that dominates
everything in this table. The per-solve figure is a marginal cost, not an invoice.

**`claude-fable-5` remains the quality ceiling.** It solves twice what the box does, 12 of 15, and the box
solved nothing it missed. At $1.3824 per solved task it costs 11.1× the box, so the routing question is
unchanged in shape: the box is the cheap tier that can be trusted with the work it can finish, and the
question is which work that is.

## Reproducing

```bash
export KUBE_CONTEXT=distai-eks NAMESPACE=swe-pilot
export STRATOCLAVE_HOST=<gateway host> STRATOCLAVE_DEFAULTS=<gateway repo>/backend/mvp/defaults
export STRATOCLAVE_API_KEY=<token>
export QWEN_LOCAL_ENDPOINT_URL=http://qwen-serving.qwen-trial.svc.cluster.local:8000/v1/chat/completions
export SUBSET=<the fifteen> PASS=fc PROTOCOL=function-calling

POLICIES=self-hosted-always ./sweep.sh
POLICIES=premium-always ./sweep.sh
TIERS=$PWD/tiers.function-calling.json POLICIES=cheap-always ./sweep.sh   # reasoning off, see above
```

Two operational notes for anyone repeating this. The instance images are 1-3 GB and a node holds 20 GiB, so
`run.sh` now declares an `ephemeral-storage` request — without it the kubelet reached DiskPressure and
evicted a running episode mid-pull, twice, on the same node. And the gateway's personal credit is denominated
in tokens and was exhausted at the start of this run; the box arms are unaffected because they address the
in-cluster service directly.

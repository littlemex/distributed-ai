# Measurement harness

One expensive measurement, and a report that is otherwise free.

The expensive thing is a **correctness matrix**: every arm answers every question,
through the router, with the model pinned. Once that exists, the best single arm,
the cheapest arm, an existential upper bound, a uniform random choice, and any
offline per-domain assignment policy are all readings of the same file and cost
nothing further. Only the router deciding for itself needs its own traffic,
because the selector's latency and load terms move with live traffic and
end-to-end latency and failures exist only on the data path.

An **arm is a member at one reasoning effort**, not a member. v1 drew the frontier
over members and found that routing between them bought no accuracy; the effort
dial moves accuracy, cost and latency together inside a single member, and a
frontier drawn without it omits the deployable alternatives a router should be
compared against. The pool file declares which levels each member gets
(`effort_levels`), a member with no declaration gets the default level only, and
`plan` prints the resulting arm count before anything is spent. Levels are never
compared across providers as levels — GPT's `low` and Grok's `minimal` share no
unit — only the measured points are.

```
collect.py    plan | classify | matrix | mixed       spend, or find out what it would cost
analyze.py                                           arms, frontier, intervals, audit
run.sh        <run-id> <collect.py args...>          the same, as a Job in the cluster
fetch.sh      <run-id>                               copy a run's results out
harness/                                             the library the two CLIs share
```

## Why it runs in the cluster

The router's Service is ClusterIP. A run driven from a laptop has to go through a
port-forward, which puts a laptop's sleep timer on the critical path of something
that takes an hour. `run.sh` submits a Job instead, and the results land on a
shared volume that outlives it.

There is no purpose-built image: the harness arrives as a ConfigMap, its
dependencies come from PyPI, and the upstream benchmark is cloned at a pinned
commit — which also records whose datasets and whose scorer produced the numbers.

## What the report is careful about

Five choices here exist because the obvious alternative quietly favours one arm.

**"Not significant" is never reported as "the same".** An interval containing zero
means the data cannot resolve the difference; at a few hundred questions per fold it
will contain zero even when the truth is a two-point loss. So the claim "no less
accurate, for less money" comes from a one-sided non-inferiority test against a
margin fixed in advance — the same margin the assignment rule was allowed to trade
away — and the conclusion is re-derived at several margins, because a verdict that
holds at only one is a product of the rule.

**The routed arm is scored on the pinned arms' questions.** Failures land on the long,
hard questions, so an arm scored on whatever it happened to answer gets an easier
population. The routed arm gets the same denominator, its failures count as wrong
(the router is fail-closed), and a call the router answered without saying which
member served it is excluded rather than costed at zero.

**Routed and pinned are collected in one interleaved pass** (`mixed`). Providers drift
over hours and a balance drains as a run proceeds; collecting the two arms in
different time windows would put all of that into exactly the comparison the
benchmark exists to make.

**Baselines are chosen on the fitting fold, not the fold they are scored on.** The
router is frozen before the test fold opens, so "the cheapest member" is chosen by
its cost on calibration. Anything else holds the baseline to a looser standard than
the router.

**The mixture frontier is resampled with the arm.** A convex hull is a chain of
maxima, so on noisy data it sits above the truth and biases every gap against the
router. The reported gap comes from a bootstrap that rebuilds the hull inside each
resample.

Two invariants are enforced rather than trusted: every scored call must have been
answered upstream (the router runs a semantic cache, and a hit costs nothing), and a
repeated `(question, member)` cell stops the load instead of letting file order
decide which answer counts.

## Run it

```bash
export KUBE_CONTEXT=<context of the cluster running the router>
export STRATOCLAVE_DEFAULTS=<gateway repo>/backend/mvp/defaults

# what a run would cost, without spending anything
./run.sh plan-01 plan --dataset mmlu --samples 200 \
  --categories math law health engineering economics philosophy "computer science"

# the expensive one: every arm, every calibration question
./run.sh calib-01 matrix --fold calibration --dataset mmlu --samples 200 \
  --categories math law health engineering economics philosophy "computer science"

# the test fold: the pinned matrix and the routed arm, interleaved in one pass
./run.sh test-01 mixed --arm multi_factor --fold test --dataset mmlu --samples 200 \
  --categories math law health engineering economics philosophy "computer science"

./fetch.sh calib-01
```

Then, locally, with no further spend:

```bash
./analyze.py --matrix results/calib-01/*.jsonl results/test-01/*.jsonl \
             --fit-fold calibration --fold test \
             --decisions results/cls-measured/decisions-all.jsonl \
             --summary results/quality-calibration.json
```

`--summary` writes the file `build_config.py --quality-from` reads, so a second
deployment can replace the router's price-prior quality scores with measured
accuracy. It is written from the fitting fold, never the test fold: seeding the
router from the numbers it will be judged on would fold the test set into the
fitting.

## Things that will bite

- **The classification API needs two settings, not one.** It binds to loopback by
  default, so the Service's `classify-api` port advertised an endpoint nothing
  could reach. Widening the bind alone makes the router refuse to start it: a
  non-loopback address demands either `remote_exposure` — which is about exposure
  beyond the cluster — or `VLLM_SR_MANAGEMENT_INTERNAL_LISTENER=true`. Both are set
  now, in the generated config and on the router container. A router deployed
  before that needs a port-forward, which is roughly three times slower.
- **The classifier shares the router's CPU limit with the request path.** Running
  a classification sweep during a measurement starves it. Run them one at a time.
- **No temperature is legal across this pool.** Claude 5 rejects the field as
  deprecated, GPT-5.6 accepts only its default, others accept 0. The harness sends
  none and each member decodes at its own default. That costs determinism; a
  different value per member would cost comparability.
- **The completion budget decides who looks accurate.** At 64 tokens, four of ten
  members could not emit an answer letter at all — the reasoning-capable ones
  spend the budget thinking. `analyze.py` prints the per-member unparsed rate
  before any comparison for exactly this reason: a rate that differs across the
  pool means part of the accuracy column is answer formatting. The budget is a cap
  and not a charge, so it is set high rather than tight: an arm that stops at two
  hundred tokens costs the same whatever the cap is, and only the arms that use it
  pay. Every run prints the per-arm rate of `finish_reason = length`; anything
  above a couple of percent means the cap, not the model, decided part of that
  arm's score.
- **High effort is unmeasurable without streaming.** The gateway caps a
  non-streaming read at fifty seconds on purpose, so a slow call fails as a
  parseable JSON 502 rather than as an HTML timeout from the CDN. `grok-4.6` at
  `high` exceeds that. Runs therefore stream by default, which also makes TTFT and
  the visible decode rate measurable; `--no-stream` exists only to reproduce a v1
  number, and mixing the two paths inside one run would put the path's own latency
  into the between-arm comparison.
- **A rejected effort level retires the arm.** Providers change the supported set
  without notice, and a 400 on `reasoning_effort` means the arm has ceased to
  exist rather than that a question went unanswered. The first rejection is
  recorded as the evidence, the arm's remaining cells are not attempted, and the
  run prints what it retired. Scoring a retired arm on the subset it did answer
  would compare arms over different question sets.
- **A question one member failed is dropped from every arm.** Keeping it would
  compare a nine-member pool against a ten-member one and call the difference
  routing.
- **Resume is per cell, and a failure counts as done.** Re-running with `--resume`
  skips cells already recorded, including failed ones, so no question gets more
  attempts in one arm than in another.

# Runbook — VSR front door

## What this deploys

One pod holding the Semantic Router (ExtProc) and Envoy. Envoy terminates the
OpenAI-compatible request, the router classifies it and names a pool member, and
Envoy dials whichever upstream that member lives behind:

- `sclv/*` members go to the billing gateway over TLS, which reserves budget,
  signs the Bedrock or bedrock-mantle call, and settles;
- `local/*` members go straight to an in-cluster vLLM service.

The router and Envoy configs are generated, never hand-edited. `build_config.py`
joins three sources: `pool.yaml` (who takes part and in what role), and the
gateway's own `models.json` and `pricing.json` (model ids and rates). Adding a
member is a `pool.yaml` edit plus a redeploy.

## Deploy

Everything environment-specific comes from the environment:

```bash
export KUBE_CONTEXT=<kubectl context of the target cluster>
export STRATOCLAVE_HOST=<gateway host>
export STRATOCLAVE_API_KEY=<gateway bearer token>
export QWEN_LOCAL_ENDPOINT=<service>.<namespace>.svc.cluster.local:8000
export STRATOCLAVE_DEFAULTS=<path to the gateway repo>/backend/mvp/defaults
./vsr/deploy.sh
```

The first start downloads the classifier and embedding models onto the PVC, so
allow several minutes before the pod reports ready. Progress:

```bash
kubectl --context "$KUBE_CONTEXT" -n vsr-bench logs deploy/vsr -c router --tail=20
```

`startup_complete` lists the loaded decisions, one per declared domain.

## Send a request

```bash
kubectl --context "$KUBE_CONTEXT" -n vsr-bench port-forward deploy/vsr 18801:8801 &
curl -sS -D - http://127.0.0.1:18801/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model":"vllm-sr/mom-bench","max_tokens":40,
       "messages":[{"role":"user","content":"What is the derivative of x^3?"}]}'
```

The routing decision comes back in the response headers, which is what the
harness records per request:

| Header | Meaning |
| --- | --- |
| `x-vsr-selected-model` | the pool member that answered |
| `x-vsr-selected-decision` | which decision matched, so the classified domain is visible |
| `x-vsr-selected-confidence` | classifier confidence for that domain |
| `x-vsr-selected-algorithm` | the selector that chose the member |
| `x-vsr-response-path` | `upstream` for a real call, so a cache hit cannot be mistaken for one |

A single-model baseline is the same request with the member's own name as
`model`, so a pinned run and a routed run traverse the identical data path and
differ only in who chose the model.

## Verified 2026-08-24 (JST)

| Path | Request | Result |
| --- | --- | --- |
| Routed, gateway leg | `vllm-sr/mom-bench`, a calculus question | 200; classified `math` at 0.98, selected `sclv/claude-opus-5`, answered by Bedrock Converse |
| Pinned, in-cluster leg | `local/qwen3.8-27b` | 200; answered by the in-cluster vLLM, served model `Qwen/Qwen3.8-27B` |
| Pinned, gateway leg | `sclv/grok-4.6` | 200; answered through bedrock-mantle |

The gateway's own usage history recorded the two gateway calls, which is the
independent confirmation that a routed call is a charged call. The in-cluster
call is deliberately absent from it: that member does not pass through the
gateway, so its cost has to be computed from the `vllm` rate row rather than
read from the ledger.

## Measuring

The harness lives in `bench/` and has its own README. The shape of a campaign:

| Step | Command | Spend |
| --- | --- | --- |
| Size it | `./run.sh plan-01 plan --samples 200 ...` | none |
| Decisions and selector choices | `./run.sh cls-01 classify ...` | none |
| The matrix, per fold | `./run.sh calib-01 matrix --fold calibration ...` | dominant |
| The router deciding | `./run.sh routed-01 routed --arm multi_factor --fold test ...` | one call per question |
| The report | `./analyze.py --matrix ... --fit-fold calibration --fold test` | none |

Only the matrix is expensive, and it is what makes every reference line except a
routed arm free. Measured on this pool at a 2048-token budget: about 540
gateway-charged tokens per call, so a ten-member matrix costs roughly 5,400 tokens
per question.

A run can be enlarged after the fact. `--samples` extends the question set rather
than reshuffling it, and `--resume` skips cells already recorded, so raising 200 to
300 pays only for what is new.

Before the routed arms, redeploy the router twice over:

1. with `--quality-from` pointing at the calibration summary, so its quality
   scores are measured rather than a price prior;
2. with `--weights quality=0.6,cost=0.4`, because the latency and load terms make
   the selector's choice depend on how hard the harness is pushing — which would
   make the routed arm a function of its own concurrency.

## Things that will bite

- **The self-hosted member serves two sequences.** vLLM runs with
  `--max-num-seqs=2`, so concurrency above that queues inside that pod. A run
  that drives more will report the queue as latency for `local/*` only.
- **Three members are priced as a deliberate over-charge.** Bedrock publishes no
  list price for Gemma, Nemotron and Qwen3, so the gateway's rate table defaults
  them to the Opus tier and the router's cost factor inherits that. Cost-aware
  routing therefore under-uses those three. A price source that supplies real
  rates fixes it without touching the router.
- **Quality scores are a price prior until a calibration run exists.** They are
  seeded from the rate ordering, which by construction cannot distinguish the
  three Opus-priced members. Feed measured accuracy back with
  `build_config.py --quality-from`.
- **A failed ExtProc fails the request.** `failure_mode_allow` is off on purpose:
  a request that skipped the router would look like a normal answer while
  belonging to no arm.
- **No route means 503, not a default upstream.** Envoy's last route is an
  explicit error, so a decision that named nothing is visible instead of quietly
  landing on the first cluster.

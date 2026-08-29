# serving — the vLLM / SGLang serving reference

A maintained asset, not an experiment record. It carries no date because its truth is the current
code; the dated directory it grew out of (`2026-08-19-qwen3-8-27b-vllm-eks/`) is frozen as the record
of that experiment and points here.

```bash
./scripts/deploy.sh --model qwen3.6-35b-a3b --tp 2 --replicas 2 --only serving --skip-pool
./scripts/deploy.sh --down
```

## What is where

| Path | What it is |
| --- | --- |
| `models/<name>/` | Everything that differs between models: `model.env` (repo id, native window, YaRN factor), `profiles.env` (window/concurrency table and tuning knobs), `values.yaml` (the vLLM overlay), `FACTS.md` (facts from the checkpoint plus what was measured on this deployment) |
| `charts/vllm-serving/` | The Helm chart. One release serves one model on one node's GPUs |
| `pool/` | The Karpenter NodePool for the GPU node |
| `alias-vllm.yaml`, `alias-sglang.yaml` | The stable `qwen-serving` Service the agents target. The vLLM one is rendered with the engine's derived name rather than applied as-is |
| `sglang/` | The optional SGLang engine: image build and manifests |
| `scripts/deploy.sh` | Bring-up and teardown. `--model` selects a directory under `models/`, `--tp` the tensor-parallel width, `--replicas` how many engines share the node |

## The three flags that matter, and why

`--model` exists because a model swap should be a flag and not an edit in four places. The Deployment's
name is derived from the repo id by the same normalisation the chart applies, and deploying a
different model removes the previous one first: four L40S hold one engine, so a leftover Deployment
would keep the GPUs and the new one would never schedule.

`--tp` matters for more than speed. vLLM replicates KV heads across ranks when `num_kv_heads` does not
divide the width, so Qwen3.6-35B-A3B — which has two — stores its cache twice at TP=4 and once at
TP=2. Measured: 40 KiB per token against 20.3.

`--replicas` is how the node gets used properly. TP=2 on two GPUs reached 94% of the prefill and 82%
of the decode of TP=4 on four, so two replicas behind the one Service do more work than one four-way
replica: 4,346,180 tokens of KV between them against 3,092,774, and aggregate prefill of 17,947 tokens
a second at sixteen requests in flight.

## After a deploy, read what the engine actually did

`deploy.sh` prints the effective engine settings once the rollout finishes — prefix caching,
speculative config, KV dtype, window, sequence cap, KV cache size. vLLM declines settings a model does
not support without saying so on the command line: prefix caching was asked for on a hybrid-attention
model and the engine reported `enable_prefix_caching=False`, which turned one measurement into a
measurement of a disabled flag. A configuration's intent is not evidence of its effect.

## Adding a model

Copy the closest directory under `models/`, put the repo id in `model.env`, work the KV geometry out of
the checkpoint's `config.json` into `profiles.env`, and keep `FACTS.md` honest about which numbers are
measured and which are still guesses.

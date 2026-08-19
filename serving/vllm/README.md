# vllm/ — single-node vLLM serving stack

Serves one model per release on a Neuron-free GPU Karpenter pool, exposing vLLM's
OpenAI-compatible API (`/v1/models`, `/v1/chat/completions`). Single-node tensor parallel;
multi-node is out of scope (see `serving/README.md` non-goals).

## Layout

```
charts/vllm-serving/   Helm chart (Deployment + Service). helm template | kubectl apply.
overlays/<id>.yaml     per-model tuning (layered on the chart's values.yaml)
scripts/up.sh          render + apply + wait for rollout
scripts/port-forward.sh  forward the Service to localhost (demo only)
scripts/run_smoke.py   /v1/models + chat + tool-call assertions
```

Model facts referenced by the overlays live in `serving/models/<id>.yaml`.

## Prerequisites (cluster contract)

- A GPU pool exists whose `node-role` label matches the overlay's `nodeRole`, backed by
  instances with enough aggregate VRAM for the chosen `tensorParallelSize`. The chart selects
  by pool label, never by instance type. Adding the pool is an `infra/eks` change
  (`accelerator_pools`), not a serving change.
- NVIDIA device plugin present (installed by infra when a GPU pool exists).
- Namespace exists (the chart does not create it; the repo uses `distai`).
- Gated models only: a `hf-token` Secret with key `token`; set `hfTokenSecret`.

## Quick start

```bash
cd serving/vllm
export KCTX=distai-tokyo NAMESPACE=distai
./scripts/up.sh qwen3.8-27b
./scripts/port-forward.sh qwen3.8-27b 8000 &
python3 scripts/run_smoke.py --base-url http://localhost:8000 --model Qwen/Qwen3.8-27B
./scripts/up.sh qwen3.8-27b --down   # tear down (GPU node is reclaimed by Karpenter when idle)
```

Cold start on a fresh node is not instant: node launch (2-4 min) + image pull (10-20 GiB) +
weight download (`Qwen3.8-27B` ≈ 54 GiB) + graph capture/warmup. Budget 15-40 min the first
time; the `startupProbe` is sized for it.

## Qwen3.8-27B specifics (why the overlay looks the way it does)

- Architecture `qwen3_5` (`Qwen3_5ForConditionalGeneration`) is registered in vLLM ≥ 0.27.0;
  the image is pinned to `vllm/vllm-openai:v0.27.1`. A `--load-format dummy` run is the fastest
  way to confirm the architecture/kernels import before downloading 54 GiB.
- It is a VLM (image-text-to-text) and a hybrid model: 48 of 64 layers are linear-attention
  (Gated DeltaNet). Prefix caching is disabled (`enablePrefixCaching: false`) because
  recurrent-state layers do not support it — do not rely on cheap repeated system prompts.
- Weights (~54 GiB, bf16) require tensor parallel ≥ 2; the overlay uses TP4 on `g6e.12xlarge`
  (4× L40S). `num_key_value_heads: 4` divides TP4.

## Tool calling

An agent backend needs structured tool calls, not just chat. `run_smoke.py` asserts a
tool-enabled request returns `finish_reason: tool_calls` with valid-JSON arguments. If the
engine has no tool-call parser for the model, tool calls come back as raw text and agents will
not work even though chat does — verify this before wiring opencode/kiro.

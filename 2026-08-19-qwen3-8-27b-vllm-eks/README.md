# Serving Qwen3.8-27B with vLLM on EKS (GPU, single node)

A dated experiment: stand up a single-node vLLM OpenAI-compatible server for
`Qwen/Qwen3.8-27B` on a Neuron-free GPU Karpenter pool, and verify it works end to end
(model list, chat, and structured tool calls for an agent backend). The base cluster
(`infra/eks`) is **not modified**; this directory carries everything that `kubectl delete`
can remove — the GPU pool manifest, the serving chart, per-model tuning, and scripts.

If a second serving experiment reuses this skeleton, the reusable parts (chart, scripts,
model-facts/overlay split) are candidates for extraction into a permanent `serving/vllm/`
top-level directory — but not before then.

## Model

`Qwen/Qwen3.8-27B` (`architecture: Qwen3_5ForConditionalGeneration`, `model_type: qwen3_5`).
A VLM (image-text-to-text) with a hybrid attention stack: 48 of 64 layers are
linear-attention (Gated DeltaNet), 16 are full attention. bf16 weights ≈ 54 GiB.
Facts live in [`models/qwen3.8-27b.yaml`](models/qwen3.8-27b.yaml); the tuning derived from
them is in [`overlays/qwen3.8-27b.yaml`](overlays/qwen3.8-27b.yaml).

## Layout

```
pool/nodepool-gpu-l40s.yaml   Karpenter NodePool: g6e.12xlarge (4x L40S), reuses the
                              gpu-ddp EC2NodeClass. kubectl-applied; not a terraform change.
charts/vllm-serving/          Helm chart (Deployment + Service). helm template | kubectl apply.
overlays/qwen3.8-27b.yaml     per-model tuning layered on the chart values
models/qwen3.8-27b.yaml       model facts (config.json-derived), separate from tuning
docs/SCHEMA-models.md         proposed facts-vs-tuning schema (extraction candidate)
scripts/up.sh                 render + apply + wait for rollout
scripts/port-forward.sh       forward the Service to localhost (demo only)
scripts/run_smoke.py          /v1/models + chat + tool-call assertions
opencode/                     opencode custom-provider config + how to drive the model
```

## Prerequisites

- `distai-eks` (ap-northeast-1) reachable; kubeconfig context (e.g. `distai-tokyo`).
- NVIDIA device plugin present (installed by infra when a GPU pool exists).
- GPU quota: g6e.12xlarge is 48 vCPU; "Running On-Demand G and VT instances" must cover it.

## Run

```bash
export KCTX=distai-tokyo NAMESPACE=distai
kubectl --context "$KCTX" apply -f pool/nodepool-gpu-l40s.yaml     # one g6e.12xlarge pool
cd scripts
./up.sh qwen3.8-27b                                                # deploy + wait for rollout
./port-forward.sh qwen3.8-27b 8000 &
python3 run_smoke.py --base-url http://localhost:8000 --model Qwen/Qwen3.8-27B
./up.sh qwen3.8-27b --down                                         # remove workload
```

Cold start on a fresh node: node launch (2-4 min) + image pull + weight download (~54 GiB)
+ compile/warmup. Observed ≈ 9.5 min to Ready on this cluster. The GPU node is reclaimed by
Karpenter once idle (`consolidationPolicy: WhenEmpty`). Delete the pool to be certain:
`kubectl --context $KCTX delete -f pool/nodepool-gpu-l40s.yaml`.

## Findings

- vLLM `v0.27.1` (upstream `vllm/vllm-openai:v0.27.1`) registers
  `Qwen3_5ForConditionalGeneration` and initializes the hybrid engine (mamba / GDN
  splitting ops present) — no custom image needed.
- Hybrid linear-attention: prefix caching is disabled (`--no-enable-prefix-caching`).
- Tool calling needs `--enable-auto-tool-choice --tool-call-parser qwen3_coder`: the
  chat_template emits Qwen3 XML (`<tool_call><function=..><parameter=..>`), which the
  `qwen3_coder` parser handles (`hermes` expects JSON and would not parse it).
- TP4 on g6e.12xlarge (`num_key_value_heads: 4` divides 4). `max_model_len` capped to 32768
  (native 262144).
- Served in non-thinking mode by default (`--default-chat-template-kwargs '{"enable_thinking":
  false}'`): the Qwen3-family thinking mode under greedy/low-temp decoding endlessly repeats and
  never emits a stop token, which stalls an agent loop. `enable_thinking=false` returns a clean
  2-token answer; a per-request `chat_template_kwargs` can re-enable it.
- opencode connects to this endpoint as a custom provider and completes a full agent tool loop
  (its `read` tool) against the self-hosted model — see [`opencode/`](opencode/).

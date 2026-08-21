# serving

The model-serving reference for `Qwen/Qwen3.8-27B`. Two engines expose the same OpenAI-compatible
API and the same `--served-model-name Qwen/Qwen3.8-27B`, so agents are unaffected by the choice.
`deploy.sh` points the `qwen-serving` Service alias at whichever engine is deployed.

## Engines

| | vLLM (default) | SGLang (opt-in) |
|---|---|---|
| Speedups | FP8 (online) + MTP(3) self-speculative | DFLASH2 + FP8 + fp8 KV cache |
| Context | YaRN 1M | YaRN 1M |
| tool-calling / image / video / 1M | verified | not verified |
| Image | upstream `vllm/vllm-openai` | custom image required (see `sglang/image/`) |
| TPOT c=1 | ≈ 9.4 ms | ≈ 8.1 ms (raw bench, without the tool-calling path) |

vLLM is the default because every client here is a tool-calling agent and the vLLM path is verified
end to end; MTP is lossless and FP8 is near-lossless. The ≈13% TPOT edge SGLang shows in a raw
benchmark does not yet justify shipping an engine whose agent-facing features are unverified.

`Qwen/Qwen3.8-27B` ships a 1-layer MTP head, so MTP needs no separate draft model. `num_speculative_tokens: 3`
reuses that head multi-step. The rationale and measurements are recorded under
[`../experiments/`](../experiments/): MTP in `mtp/`, the FP8 and SGLang/DFLASH ladders in
`fp8-latency/` and `sglang-dflash/`.

## SGLang promotion criteria

SGLang stays experimental until all four are met (currently 0/4):

| # | Criterion | Pass basis | State |
|---|---|---|---|
| a | tool-calling on all four agents | parse success on each | not met |
| b | image and video input | correct read-back | not met |
| c | 1M needle with DFLASH2 active | needle retrieved | not met |
| d | composed-config TPOT below vLLM | vs the value recorded in `models/qwen3.8-27b.yaml` | not met |

## Files

- `vllm/charts/vllm-serving/` — Helm chart. `strategy: Recreate` (a GPU node holds fixed devices, so
  a rolling update cannot stand up a second pod). Rendered with `helm template | kubectl apply`.
- `vllm/values/qwen3.8-27b.values.yaml` — the tuning (FP8, MTP, `limit-mm`, YaRN). Tuning, not facts.
- `sglang/` — manifests, the custom-image build (`image/`), and its own README.
- `common/model.env` — the four values shared by both engines (model id, served name, YaRN factor,
  max context), injected at deploy so the two definitions cannot drift.
- `pool/nodepool-gpu-l40s.yaml` — the production on-demand pool (L40S x4). Experiment pools live under
  `../experiments/`.
- `models/qwen3.8-27b.yaml` — config.json-derived facts plus one representative measured TPOT row per
  engine (with its conditions); history lives in `../experiments/`.
- `alias-vllm.yaml` / `alias-sglang.yaml` — the `qwen-serving` Service, one static file per engine.

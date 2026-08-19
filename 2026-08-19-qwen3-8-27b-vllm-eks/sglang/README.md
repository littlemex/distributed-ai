# SGLang + DFLASH2 (dflash2) — status: blocked on a source build

Goal: serve Qwen/Qwen3.8-27B with DFlash2 speculative decoding (draft model
`incoai/Qwen3.8-27B-DFlash2`) and benchmark throughput / TTFT / TPOT vs the vLLM
autoregressive baseline.

## Finding (verified 2026-08-20)

DFlash2 is too new to run from any published image:
- The draft model `incoai/Qwen3.8-27B-DFlash2` has `architectures: ["DFlash2DraftModel"]`,
  `auto_map: null`, and ships **no custom modeling code** (only config.json + model.safetensors).
  So the serving engine itself must define `DFlash2DraftModel`.
- vLLM: DFlash2 is PR #52816, **open / not merged** → not in v0.27.1 nor main. Needs a source build.
- SGLang: main **does** define `DFlash2DraftModel` (python/sglang/srt/models/dflash.py, in
  EntryClass), but the published images do not yet include it:
    - `lmsysorg/sglang:dev` and `:nightly-dev-cu12-20260818-*` both fail at startup with
      `ValueError: Cannot find model module. 'DFlash2DraftModel' is not a registered model`.
    - i.e. DFlash2 landed in sglang main after the 2026-08-18 nightly. A newer nightly (or a
      source build from current main) is required.

## To run it (when unblocked)

- Easiest: use a sglang published image dated after the DFlash2 merge (check
  `lmsysorg/sglang` tags for a nightly newer than the merge), then `kubectl apply -f pod/sglang-dflash.yaml`.
- Otherwise: build sglang (+ sgl-kernel) from current main into a custom image (in-cluster
  BuildKit or the zenns3 docker host), push to ECR, and set that image in pod/sglang-dflash.yaml.

`pod/sglang-dflash.yaml` (DFLASH args, draft model, TP4 on a spot g6e.12xlarge) and
`../pool/nodepool-gpu-l40s-spot.yaml` are ready; only the image is blocked.

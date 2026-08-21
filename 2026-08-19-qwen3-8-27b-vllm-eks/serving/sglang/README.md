# SGLang engine (opt-in, experimental)

SGLang with DFLASH2 speculative decoding is a faster alternative to the default vLLM engine, but it
is **not the default** and is **not yet promoted**: its agent-facing features are unverified and it
needs a prebuilt custom image. Use it only if you accept those caveats.

Why vLLM is the default: every client here is a tool-calling agent, and the vLLM path (FP8 + MTP)
is verified end to end at ≈9.5 ms TPOT (c=1). SGLang benches faster (≈8.1 ms raw), but that number
is without the tool-calling path, and the composition below is unverified.

## Promotion criteria (0/4 — must all pass before SGLang can become the default)

| # | Criterion | Pass basis | State | Measured | sglang commit |
|---|---|---|---|---|---|
| a | tool-calling on all four agents | smoke `SMOKE(c)=PASS` | not met | - | - |
| b | image and video input | correct read-back | not met | - | - |
| c | 1M needle with DFLASH2 active | needle retrieved | not met | - | - |
| d | composed-config TPOT below vLLM | vs `../models/qwen3.8-27b.yaml` (same conditions) | not met | - | - |

No row is ✅ until measured on the composed config (DFLASH2 + FP8 + fp8 KV + YaRN 1M + tool-calling
together), not from separate runs.

## Use it

1. Pin the image inputs in `image/image.env` (`BASE_IMAGE` digest, upstream `SGLANG_COMMIT`, `TAG`).
2. Build and push the custom image (bakes DFlash2 at build time; no in-cluster build at pod start):
   ```bash
   QWEN_REGION=<region> ./image/build.sh
   ```
3. Deploy the engine (switches the `qwen-serving` alias to SGLang; this is a planned-downtime switch
   because one engine occupies the GPU node):
   ```bash
   ./scripts/deploy.sh --engine sglang
   ```
   `deploy.sh` checks the image exists in ECR first and stops with build guidance if it does not. It
   runs smoke in `--report` mode, so a `SMOKE(c)=FAIL` records "not promotable" without failing the
   opt-in deploy.

## Notes

- The manifest (`manifests/qwen3.8-27b.sglang.yaml`) serves `--served-model-name Qwen/Qwen3.8-27B` on
  `:8000` so agents are unaffected by the engine choice. Shared values come from `../common/model.env`.
- SGLang main builds a Rust server, so building at pod start takes ~15 min; baking it into the image
  avoids that on every start.

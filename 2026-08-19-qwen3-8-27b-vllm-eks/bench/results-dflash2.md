# dflash2 (DFLASH2 speculative decoding) — SGLang vs vLLM baseline

Model Qwen/Qwen3.8-27B, g6e.12xlarge (L40S x4, TP4). dflash2 served with SGLang
(nightly-dev-cu12-20260818 image + sglang python installed from main at start, so
DFlash2DraftModel is present; mem-fraction-static 0.75, context 16384,
--speculative-algorithm DFLASH --speculative-draft-model-path incoai/Qwen3.8-27B-DFlash2
--speculative-num-draft-tokens 8). Baseline = vLLM v0.27.1 autoregressive (from the
concurrency sweep). Bench: `vllm bench serve`, dataset=random, input_len 512.

| concurrency | dflash2 out tok/s | dflash2 mean TPOT (ms) | vLLM baseline out tok/s | vLLM baseline mean TPOT (ms) | TPOT speedup |
|---|---|---|---|---|---|
| 1 | 79.95  | 10.92 | 39.08  | 22.71 | ~2.1x |
| 2 | 119.98 | 13.66 | 67.93  | 26.23 | ~1.9x |
| 4 | 202.50 | 17.82 | 119.43 | 27.50 | ~1.5x |

Caveats (faithful):
- `dataset=random` UNDERSTATES speculative decoding: random tokens are unpredictable, so the
  draft acceptance rate is low. On coherent real text/code the acceptance (and speedup) is higher
  (inco.ai reports 2.7-3.4x). Our ~1.5-2.1x on random tokens is a conservative floor.
- Cross-engine (SGLang vs vLLM), so a small part of the delta is engine overhead, not just
  speculative decoding. A SGLang-without-DFLASH control would isolate it (not run here).
- dflash2's DFLASH2DraftModel is not in any published image yet (see ../sglang/README.md); it was
  obtained by pip-installing sglang from main on top of the nightly image at container start.

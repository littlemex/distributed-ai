# FP8 (online) vs bf16 — single-user TPOT, same node/profile

g6e.12xlarge (L40S x4, TP4), Qwen/Qwen3.8-27B, vLLM v0.27.1, max-model-len 8192, max-num-seqs 20,
CUDA graphs on, prefix caching off. Clean control: SAME pod/node, only `--quantization=fp8`
toggled (online dynamic FP8, CutlassFP8ScaledMMLinearKernel / Fp8PerTensorOnlineLinearMethod).
Bench `vllm bench serve`, dataset=random, in512/out256, --ignore-eos.

Per-GPU weights+non-torch (from startup log): bf16 13.21 GiB, FP8 8.77 GiB (weights ~halved).

| concurrency | bf16 TPOT (ms) | FP8 TPOT (ms) | TPOT speedup | bf16 out tok/s | FP8 out tok/s |
|---|---|---|---|---|---|
| 1 | 22.51 | 16.13 | 1.40x | 42.09  | 57.64  |
| 2 | 25.71 | 17.22 | 1.49x | 73.21  | 106.33 |
| 4 | 27.06 | 18.57 | 1.46x | 132.08 | 183.68 |

## Roofline reconciliation (L40S 864 GB/s, TP4)
- bf16 weight-read floor per token = 13.5 GiB / 864 GB/s ~= 15.6 ms. Measured bf16 TPOT 22.5 ms
  is ~1.4x the floor -> vLLM already runs near the memory-bandwidth roofline; kernel tuning has
  little headroom left.
- FP8 halves weight bytes -> floor ~7.8 ms, but measured FP8 TPOT is 16 ms. The ~8 ms gap is
  FIXED overhead that quantization does not shrink: PCIe TP all-reduce (no NVLink on g6e), the
  linear-attention (Gated DeltaNet) + full-attention kernels, dynamic per-token activation
  quantization, sampling, and framework overhead. Once weights are cheap, this fixed cost
  dominates -> that is where the remaining TPOT levers are (TP degree, speculative decoding).

## Levers, ranked for single-user (concurrency <= 20) TPOT
1. Speculative decoding (DFLASH2): already measured ~2x TPOT (10.9 ms @ c1) — biggest single win;
   trades spare compute (abundant at low concurrency) for latency.
2. FP8 weights: measured ~1.45x here; stacks UNDER spec decode (half bytes x multi-token/pass).
3. FP8 + DFLASH2 stacked: expected best on this hardware (see results-fp8-dflash2.md).
4. TP2 vs TP4: fewer PCIe all-reduce hops vs more per-GPU bytes; at FP8 weights are cheap so
   trading comm for bandwidth may help — measure.
5. Hardware ceiling: L40S 864 GB/s is the real cap. HBM GPU (H100 3.35 TB/s ~4x, H200/B200)
   is the only path to a step-change in TPOT; not a tuning knob.

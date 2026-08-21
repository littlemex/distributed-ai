# FP8 + DFLASH2 stacked (lowest TPOT on L40S) — measured

g6e.12xlarge (L40S x4, TP4), Qwen/Qwen3.8-27B. SGLang (nightly image + sglang python from main at
start so DFlash2DraftModel is present) with `--quantization fp8` on the target + DFLASH speculative
decoding (draft incoai/Qwen3.8-27B-DFlash2, num-draft-tokens 8), context 16384, mem-fraction 0.80.
Manifest: bench/fp8-latency/sglang-dflash-fp8.yaml. Bench: sglang.bench_serving, dataset=random,
in512/out256 (accept length reported by the server).

| concurrency | TPOT (ms) | output tok/s | accept length |
|---|---|---|---|
| 1 | 8.14  | 107.41 | 3.06 |
| 2 | 10.53 | 183.60 | 3.40 |

## The full TPOT ladder (single-user c=1, in512/out256, same GPU)
| config | TPOT c=1 (ms) | out tok/s | speedup vs bf16 | how |
|---|---|---|---|---|
| vLLM bf16 (control)           | 22.51 | 42.1  | 1.00x | baseline |
| vLLM FP8 (online)             | 16.13 | 57.6  | 1.40x | halve weight bytes |
| SGLang DFLASH2 (bf16)         | 10.9  | ~80   | ~2.1x | multi-token / forward pass |
| SGLang FP8 + DFLASH2 (stack)  | 8.14  | 107.4 | 2.77x | both, compounded |

Notes (faithful):
- Tools differ: bf16/FP8 rows use `vllm bench serve`; the DFLASH rows use `sglang.bench_serving`
  (vllm bench's --ignore-eos is rejected by SGLang's chat endpoint). TPOT = mean inter-output-token
  latency in both, so the ladder is directionally sound; treat the last two rows' absolute values
  as SGLang-bench numbers.
- accept length ~3 on random tokens means ~3 tokens accepted per target-verify pass; on coherent
  real text/code it is typically higher, so TPOT on real workloads should be <= these figures.
- These are latency profiles (context 8192-16384). At 1M YaRN context TPOT rises because the 16
  full-attention layers must read a large KV cache each token; keep context short when latency is
  the goal.
- FP8 here is online dynamic quantization (tiny quality cost, no checkpoint needed). A pre-quantized
  static FP8 checkpoint would cut startup time and is worth it if this becomes the default serving.

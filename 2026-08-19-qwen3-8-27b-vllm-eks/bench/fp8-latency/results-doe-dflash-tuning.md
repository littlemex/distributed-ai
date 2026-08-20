# DFLASH2 tuning DOE on L40S (Qwen3.8-27B, SGLang, TP4, INT4+fp8KV+YaRN 1M)

Fable-informed design. Fixed: quant=INT4(W4A16 compressed-tensors), kv=fp8_e4m3, context 1M(YaRN f4),
mem-fraction 0.60, cuda-graph-max-bs 4, DFLASH draft incoai/Qwen3.8-27B-DFlash2. Iterated via
kubectl-exec relaunch on a sleep-infinity pod (no image rebuild). Metric: code-generation prompts
(8 fixed coding tasks), greedy(temp 0), non-streaming e2e differencing TPOT = (t512 - t16)/(tok512 -
tok16) to isolate server-side per-token decode (median over prompts); accept_length from server log.

## A x B (block_size x accept_threshold) 2x2, on code prompts
| block_size | accept_threshold | TPOT p50 (ms) | accept_length | note |
|---|---|---|---|---|
| 8  | 1.0 (lossless) | 6.96 | 3.33 | baseline; practical BEST |
| 16 | 1.0            | 10.63 | 2.92 | worse: draft accuracy does not extend to 16, accept caps ~3, verify compute wasted |
| 8  | 0.5 (lossy)    | 6.58 | 3.73 | only ~5.5% faster, and lossy (rejection sampling) |
| 16 | 0.5            | 10.59 | 2.92 | no gain (accept stuck 2.92 at block16) |

Main effect A (block): 8 avg 6.77 vs 16 avg 10.61 -> block 8 dominant (-3.84 ms).
Main effect B (threshold): 1.0 avg 8.80 vs 0.5 avg 8.59 -> -0.21 ms, small.
Interaction A x B: threshold relaxation raises accept only at block 8 (3.33->3.73); at block 16 accept
is flat 2.92. DFlash2 draft is tuned for block_size 8; larger windows do not help this model.

## Compute/other knobs (toggled on best cell block8/thr1.0)
| knob | result |
|---|---|
| enable_torch_compile | CRASH: torch._dynamo/Triton `launcher() missing '_grid_2'` codegen bug in this sglang-main + INT4/DFLASH/hybrid. Unusable here (upstream bug, not misconfig). |
| enable_linear_replayssm_spec | NOT APPLICABLE: requires a KDA (kimi_linear) model; Qwen3.8 (Gated DeltaNet) is rejected. |
| num_continuous_decode_steps=2 | not measured (lowest priority; Fable predicted inert since spec already emits block tokens/step). |

## Structural finding
- 4x L40S is PCIe-only (no NVLink): SGLang logs "CustomAllreduce is disabled ... not supported on
  more than two PCIe-only GPUs" -> TP all-reduce falls back to NCCL over PCIe. This comm cost is part
  of the dflash2-regime floor (confirms the roofline reasoning that TP comm is a fixed cost once
  weights are cheap).

## 1M requirement verification (needle beyond native)
- best config block8/thr1.0: prompt 408,072 tokens, needle placed at ~375,426 tokens (well beyond
  native 262144). Model correctly located and recited the needle ("MELON-7391-KIWI"). elapsed 239.7 s.
  -> YaRN 1M genuinely works beyond native on SGLang. INT4+dflash2+fp8KV+YaRN-1M is a viable 1M config.
  (Note: thinking mode is ON in this SGLang launch — the model emits a reasoning preamble; disable it
  for a coding-agent config to cut latency-to-answer.)

## Conclusion
- On L40S, the base config (block8 / thr1.0 lossless / fp8 KV) is near the practical TPOT floor
  (~7 ms c=1 on code). Software tuning knobs give <=5.5% (lossy) or are unavailable (compile crash,
  replayssm N/A) in this build. The remaining real lever is hardware (FP4 on Blackwell / HBM GPU),
  consistent with the roofline analysis.
- Recommended serving config (1M-capable, lowest TPOT): SGLang, block_size 8, accept_threshold 1.0
  (lossless), fp8 KV, YaRN 1M, INT4 or FP8 weights (INT4 ~= FP8 at c=1; FP8 better at higher
  concurrency). Disable thinking. Productionize with a prebuilt image (the sglang-main Rust build is
  ~15 min per cold start).

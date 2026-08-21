# MTP (Multi-Token Prediction) self-speculative decoding on vLLM

Qwen3.8-27B ships a 1-layer MTP head (config text_config.mtp_num_hidden_layers=1; weights mtp.fc,
mtp.layers.0.{self_attn,mlp,norms}, mtp.norm, mtp.pre_fc_norm_*). So MTP speculation needs NO
separate draft model and is lossless (target-verified). vLLM v0.27.1 supports it for qwen3_5:
startup logs "Detected MTP model. Sharing target model ...".

Config: vLLM v0.27.1, Qwen/Qwen3.8-27B (base, has MTP weights), online FP8, TP4 g6e.12xlarge (spot),
max-model-len 8192, max-num-seqs 20, `--speculative-config '{"method":"mtp","num_speculative_tokens":N}'`.
Bench: `vllm bench serve`, dataset=random, in512/out256, --ignore-eos (same tool as the FP8 baseline).

| config | TPOT c=1 (ms) | TPOT c=2 (ms) | out tok/s c=1 | speedup vs FP8 no-spec |
|---|---|---|---|---|
| FP8 no-spec (baseline)   | 16.13 | 17.22 | 57.6 | 1.00x |
| FP8 + MTP (num_spec=1)   | 11.39 | 12.93 | 78.8 | 1.42x |
| FP8 + MTP (num_spec=3)   | 9.52  | 11.64 | 91.0 | 1.69x |
| FP8 + MTP (num_spec=5)   | not captured (measurement stopped mid-startup) | | | |

Notes:
- num_speculative_tokens>1 reuses the single MTP layer autoregressively (EAGLE-style multi-step);
  it works and helps (11.39 -> 9.52 ms from 1 -> 3). Sweet spot >=3; 5 not measured.
- vs DFLASH2 (SGLang): FP8+dflash2 8.14 ms, INT4+dflash2 7.78 ms (sglang bench, cross-engine). MTP(3)
  9.52 ms is slightly behind dflash2 but CLOSE, while staying on vLLM.
- Practical trade-off: MTP is the production-friendly path -- it drops into the existing vLLM Helm
  chart as one extra flag, is lossless, needs no separate draft, and composes with the vLLM YaRN 1M
  production config. DFLASH2 is ~15% faster but requires SGLang + a ~15-min source (Rust) build and
  extra operational complexity. For a single-user coding/research backend, MTP(3) on vLLM is the
  recommended default; DFLASH2 only if the last ~1.4 ms/token matters.
- Cross-tool caveat: MTP numbers are vllm bench (random). Real coherent code raises acceptance, so
  on-workload TPOT should be <= these. MTP is lossless so no quality gate needed.

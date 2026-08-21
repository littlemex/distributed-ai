# Concurrency sweep — Qwen/Qwen3.8-27B on g6e.12xlarge (L40S x4, TP4), vLLM v0.27.1

Profile: overlays/qwen3.8-27b-throughput.yaml (max_model_len 8192, max_num_seqs 256,
gpu_memory_utilization 0.92, enable_thinking=false). Bench: `vllm bench serve` (random,
input_len 512, output_len 128, --ignore-eos), run inside the serving pod against localhost.

| concurrency | output tok/s | total tok/s | mean TTFT (ms) | mean TPOT (ms) |
|---|---|---|---|---|
| 1   | 39.08  | 199.29  | 391.20   | 22.71 |
| 2   | 67.93  | 346.23  | 431.87   | 26.23 |
| 4   | 119.43 | 608.74  | 791.12   | 27.50 |
| 8   | 183.63 | 936.08  | 1214.02  | 34.27 |
| 16  | 250.86 | 1278.57 | 1987.81  | 48.49 |
| 32  | 318.88 | 1625.27 | 2842.42  | 78.49 |
| 64  | 363.84 | 1854.53 | 3984.11  | 145.23 |
| 128 | 390.61 | 1991.02 | 9461.98  | 252.15 |
| 256 | 399.99 | 2038.82 | 31593.63 | 374.28 |

Takeaway: output throughput saturates ~400 tok/s by concurrency 128-256 (decode compute-bound,
not memory-bound). Useful operating point ~64-128; beyond that TTFT/TPOT degrade sharply for
negligible throughput gain. Memory admits up to max_num_seqs (256) fine at short context.

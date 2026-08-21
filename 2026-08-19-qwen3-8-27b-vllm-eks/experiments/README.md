# experiments

Explorations that are not part of the production reference. Rule: when a finding is adopted into
`serving/`, only its results stay here (the canonical config lives in `serving/`); when a finding is
rejected, the whole thing is kept as a reproducible record.

| Directory | Question | Outcome |
|---|---|---|
| `concurrency-sweep/` | throughput/TPOT vs concurrency on vLLM | recorded |
| `fp8-latency/` | FP8 vs bf16 single-user TPOT (vLLM), and the g7e probe | FP8 adopted (see `serving/`); g7e capacity unavailable |
| `sglang-dflash/` | SGLang DFLASH2 speculative decoding, INT4, and a tuning DOE | not adopted as default (SGLang is opt-in; manifests kept) |
| `mtp/` | vLLM MTP self-speculative decoding | adopted into `serving/` — results only here |
| `nodepool-gpu-l40s-spot.yaml`, `nodepool-gpu-g7e.yaml` | experiment node pools (spot L40S, g7e Blackwell) | kept for reproducing the benchmarks |

Benchmarks use `vllm bench serve` / `sglang.bench_serving` with `--dataset-name random` unless a
result file states otherwise. Random input understates speculative-decode acceptance, so those
numbers are conservative relative to coherent text.

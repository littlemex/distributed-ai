# Several small vLLM engines on one GPU, with and without CUDA MPS

One script, [`mps_bench.sh`](mps_bench.sh), starts vLLM engines on a single GPU, drives them from one load driver, and writes one table. It compares three ways of using the GPU under the same offered load:

| Mode | Engines | How the GPU is shared |
|---|---|---|
| `single` | 1 | one engine gets the whole memory budget |
| `timeslice` | `ENGINES` | several engines side by side, no MPS: the GPU time-slices between their CUDA contexts |
| `mps` | `ENGINES` | the same engines under an MPS control daemon, so their kernels can run at the same time |

One load driver sends the same request set to every mode, dealing it round-robin to the engines, and timestamps every request, so each mode's throughput is measured over one wall-clock window. The request set being equal, what else changes is what sharing implies: with two engines each holds its own copy of the weights and serves half of the in-flight requests.

## Requirements

The script assumes nothing about where it runs: a workstation with an RTX 4090 or 5090, a cloud VM, or a Kubernetes Pod.

| Requirement | Why |
|---|---|
| One NVIDIA GPU, Volta or newer | MPS on Volta and later gives each client its own GPU address space |
| `nvidia-cuda-mps-control` on `PATH` | ships with the NVIDIA driver; the NVIDIA container toolkit mounts it into containers that request compute |
| vLLM with the `vllm` CLI | `vllm serve` for the engines |
| `python3` with `aiohttp`, `curl`, `nvidia-smi`, `pgrep` | the load driver (vLLM already depends on `aiohttp`), readiness checks, GPU sampling, the MPS checks |
| No MPS daemon running at start | the script refuses to start otherwise, and in `mps` mode checks that every engine registered with the daemon |

## Run

```bash
./mps_bench.sh
```

Every setting is an environment variable with a default:

| Variable | Default | Meaning |
|---|---|---|
| `MODELS` | Qwen2.5 0.5B, 1.5B and 3B Instruct | space-separated Hugging Face ids |
| `MODES` | `single timeslice mps` | which modes to run |
| `ENGINES` | `2` | engines in `timeslice` and `mps` |
| `MEM_BUDGET` | `0.84` | GPU memory fraction shared by all engines of a mode |
| `CONCURRENCY` | `16 128` | total in-flight requests, one run per value |
| `ROUNDS` | `10` | requests per in-flight slot |
| `REPEATS` | `3` | runs per mode and concurrency, each with its own request set |
| `INPUT_LEN` / `OUTPUT_LEN` | `512` / `128` | random token-id prompts of exact length, fixed output length with `ignore_eos` |
| `MAX_NUM_SEQS` | `256` | per-engine seat count, fixed so it is part of the record |
| `ENGINE_ARGS` | empty | extra `vllm serve` arguments, for example `--enforce-eager` |
| `OUT_DIR` | `./results/<timestamp>` | per-run JSON, GPU samples, engine logs, `summary.md`, `summary.json` |

Engines start one at a time, because vLLM sizes its memory from what is free when it starts, and run with prefix caching off, because repeats reuse nothing but the engines. A mode's output token rate is its total output tokens over the window from the first request's start to the last request's end; GPU utilisation is averaged over the same window.

## Kubernetes

[`eks/pod.yaml`](eks/pod.yaml) runs the script in one Pod on a `g6.2xlarge` (one L4, 24 GB) with the upstream `vllm/vllm-openai:v0.30.0` image:

```bash
kubectl create namespace mps-bench
```

```bash
kubectl -n mps-bench create configmap mps-bench-script --from-file=mps_bench.sh
```

```bash
kubectl apply -f eks/pod.yaml
```

The Pod prints `DONE` when the table is written, or `FAILED`, and keeps the results under `/results` until it is deleted.

## Results

Measured on 2026-09-25 on one NVIDIA L4 (24 GB, driver 580.178.04) in a `g6.2xlarge` Pod with 8 vCPUs, vLLM 0.30.0, `INPUT_LEN=512`, `OUTPUT_LEN=128`, `MAX_NUM_SEQS=256`, two engines in `timeslice` and `mps`, three repeats per cell. Per-run JSON, GPU samples and the MPS daemon log are under [`results/2026-09-25-l4/`](results/2026-09-25-l4/); the full tables with TTFT and TPOT are `default/summary.md` and `eager/summary.md`.

Mean output tokens per second relative to `single` (the standard deviation of every cell is under 1 percent of its mean):

| Model | Concurrency | `single` tok/s | `timeslice` | `mps` |
|---|---|---|---|---|
| Qwen2.5-0.5B-Instruct | 16 | 2351.7 | 0.53 | 0.60 |
| Qwen2.5-0.5B-Instruct | 128 | 5294.5 | 0.77 | 0.88 |
| Qwen2.5-1.5B-Instruct | 16 | 849.9 | 0.54 | 0.62 |
| Qwen2.5-1.5B-Instruct | 128 | 2045.0 | 0.77 | 0.87 |
| Qwen2.5-3B-Instruct | 16 | 448.9 | 0.53 | 0.60 |
| Qwen2.5-3B-Instruct | 128 | 1131.8 | 0.78 | 0.87 |
| Qwen2.5-0.5B-Instruct, `--enforce-eager` | 16 | 1048.9 | 0.96 | 0.98 |
| Qwen2.5-0.5B-Instruct, `--enforce-eager` | 128 | 4516.0 | 0.88 | 1.01 |

What the numbers support:

- With CUDA graphs on, MPS was faster than time-slicing in every pair, by 11 to 15 percent.
- With CUDA graphs on, two engines stayed below one engine at the same total load, at 0.60 to 0.88 of it. A single engine already had a kernel running 98 to 100 percent of the time (`nvidia-smi` utilisation, which counts time with any kernel active, not SM occupancy).
- With CUDA graphs off, a single engine at concurrency 16 had a kernel running only 44 percent of the time. MPS then came within 2 percent of one engine at concurrency 16 and above it by about 1 percent at 128, a difference three repeats cannot tell apart from none. This is relative to an eager single engine; in absolute terms the engine with CUDA graphs on stayed faster.

What they do not show: why two engines lose (halving each engine's batch and each engine reading its own copy of the weights are both consistent with the gap narrowing at higher concurrency, and neither is measured here; nor is CPU contention between two engines and the load driver on 8 vCPUs), gains on faster GPUs such as H100 where a single small-model engine is more likely to be limited by its CPU side, and loads where the second engine receives additional requests rather than half of the same ones.

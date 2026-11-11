# Optimizer step time: AdamW, Muon on gathered matrices, and FlexShard DistMuon

Muon orthogonalizes each weight matrix's update with a few Newton-Schulz iterations, which needs the whole matrix. FSDP stores every matrix sharded across ranks, so a plain implementation gathers every full gradient on every rank and repeats the same Newton-Schulz work everywhere. FlexShard in torchtitan v0.4.0 ([`torchtitan/distributed/flex_shard`](https://github.com/pytorch/torchtitan/tree/v0.4.0/torchtitan/distributed/flex_shard)) redistributes parameters for optimizer compute only, so each matrix is computed once, on one rank, and the redistribution overlaps the compute. DistMuon is its first user. This investigation times one optimizer step for each approach on one 8-GPU node.

| Optimizer | What runs |
|---|---|
| `adamw` | `torch.optim.AdamW(foreach=True)` on the sharded DTensors, the usual FSDP optimizer |
| `muon-gather` | every rank gathers every full gradient and runs `torch.optim.Muon` on all matrices |
| `distmuon` | `DistMuon` with every matrix `Owned` by one rank, BF16 Newton-Schulz, one bucket per layer |

The weights are every 2D matrix of Llama 3 8B (32 layers x wq, wk, wv, wo, w1, w2, w3, about 7 billion parameters), FP32, sharded on dim 0 over 8 ranks; gradients are random. Each optimizer gets 3 warm-up steps and 10 timed steps; a step is bracketed by a barrier and a CUDA sync, and the slowest rank's time is kept. Peak memory per rank is recorded too.

## Files

```
scripts/optimizer_step_bench.py   the benchmark (torchrun, 8 ranks)
tasks/20-optimizer-step.json      torchtitan's own DistMuon GPU test, then the benchmark
```

It uses the torchtitan venv built by `../2026-11-10-torchtitan-checkpoint-fsx-lustre/tasks/10-torchtitan-env.json`.

## Run

```bash
cd ../2026-11-10-p5e-single-node-campaign
./3.run.sh 2026-11-10-torchtitan-flexshard-muon/tasks/20-optimizer-step.json
```

## Results

Measured on 2026-11-10 (p5e.48xlarge, sa-east-1), 8 ranks, 32 layers (6.98 billion parameters in 224 matrices), 10 timed steps after 3 warm-up steps. torchtitan's own DistMuon GPU tests passed first (`7 passed`). Raw records: [`results/p5e-2026-11-10/`](results/p5e-2026-11-10).

| Optimizer | Step time, median (ms) | Peak memory per rank (GiB) |
|---|---|---|
| AdamW on sharded DTensors | 18.6 | 16.3 |
| Muon on gathered full matrices (every rank computes everything) | 1,117.6 | 85.0 |
| FlexShard DistMuon (each matrix owned by one rank) | 237.8 | 10.7 |

DistMuon took a Muon step in 21 % of the time of the gather-everything implementation and with an eighth of its memory, because each matrix's Newton-Schulz iterations run once on one rank instead of on all eight. A Muon step is still about 13 times an AdamW step here; how much of a training step that is depends on the model and the batch, which this benchmark does not measure.

## Scope

This times the optimizer step alone, on synthetic gradients, which isolates the mechanism. It does not show the effect on a full training step, where the step's share of time depends on model and batch size, and it does not reproduce the multi-node numbers in the TorchTitan update post. torchtitan v0.4.0 ships DistMuon through its Kimi test recipes; a Llama recipe that trains end to end with DistMuon would be the next step.

## Contributing upstream

This fits `examples/training/torchtitan/` as a micro-benchmark section with its own venv pinned to torchtitan v0.4.0, since FlexShard does not exist in the v0.2.2 the example pins today.

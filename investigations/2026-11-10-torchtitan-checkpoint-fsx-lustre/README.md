# Checkpoint save time for torchtitan on FSx for Lustre and on local NVMe

A checkpoint costs training time in two ways: the time the trainer stops (blocking time), and the time until the checkpoint is really on storage and could be restored (write completion). Asynchronous checkpointing trades the first for the second. The [TorchTitan update post](https://pytorch.org/blog/torchtitan-update-new-sota-models-performance-at-scale-titanrl/) reports this trade for `torch_checkpointing`, the new checkpoint library, at 512 GPUs. This investigation measures both times for Llama 3 8B on one 8-GPU node, for every checkpointer torchtitan v0.4.0 ships, against two storage targets.

| Checkpointer (recipe in `scripts/ckpt_recipes.py`) | What it does |
|---|---|
| `ckpt_dcp_sync` | Distributed Checkpoint (DCP), `async_mode="disabled"`: training waits for the whole write |
| `ckpt_dcp_async` | DCP, `async_mode="async"`: a background thread writes while training continues |
| `ckpt_dcp_async_pinned` | DCP, `async_mode="async_with_pinned_mem"`: copy to pinned host memory, then write |
| `ckpt_torch_checkpointing` | `TorchCheckpointingManager` (torch_checkpointing 0.1.1), default settings |

| Target | Path |
|---|---|
| FSx for Lustre 2.15, Persistent 2, 4.8 TiB, 1000 MB/s/TiB, EFA, striped over every OST with 16 MiB stripes | `/fsx` |
| Instance store, 8x 3.84 TB NVMe in RAID0, ext4 | `/local` |

Each run trains 21 steps from random init with the test tokenizer and the C4 sample bundled in the torchtitan repository (no gated assets), FSDP over 8 GPUs, and saves a full checkpoint (model, optimizer, scheduler, about 96 GB) every 5 steps.

## How each time is measured

| Value | Source |
|---|---|
| Blocking time | The trainer's own log line `Finished <saving or staging> the checkpoint in X seconds` |
| Write completion | `scripts/watch_ckpt.py` polls the checkpoint directory on the target and records when each step's metadata file appears (`.metadata` for DCP, the library's own name for torch_checkpointing), measured from the trainer's `Saving/Staging the checkpointer.` line. Independent of what the trainer reports |
| Step time | Time between consecutive `step:` lines of steps without a save, from a timestamp the runner prefixes to every log line |
| Size | Bytes in each step directory |

## Files

```
scripts/ckpt_recipes.py     the four torchtitan recipes (8B, test tokenizer, c4_test, full checkpoint every 5 steps)
scripts/run_variant.sh      one recipe against one target: watcher, timestamped log, cleanup
scripts/watch_ckpt.py       storage-side completion times
scripts/summarize.py        one Markdown table from every run
tasks/10-torchtitan-env.json   torchtitan v0.4.0 (commit 45e33cd) + PyTorch 2.15.0 (cu132) venv and a debug-model smoke run
tasks/20-ckpt-timing.json      4 recipes x 2 targets, then the summary
```

## Run

```bash
cd ../2026-11-10-p5e-single-node-campaign
./3.run.sh 2026-11-10-torchtitan-checkpoint-fsx-lustre/tasks/10-torchtitan-env.json
./3.run.sh 2026-11-10-torchtitan-checkpoint-fsx-lustre/tasks/20-ckpt-timing.json
```

## Results

Pending: the Capacity Block runs 2026-11-10 20:30 to 2026-11-11 20:30 JST.

## Scope

One node shows the mechanism, not the scale behaviour: at 512 GPUs the aggregate write bandwidth and the barrier costs differ. The 4.8 TiB file system is the smallest EFA-enabled size and caps aggregate throughput near 4.8 GB/s.

## Contributing upstream

`examples/training/torchtitan/` in awsome-distributed-ai pins torchtitan v0.2.2 and has only a Slurm launcher with checkpointing disabled. torchtitan v0.4.0 replaced the TOML configuration with Python recipes, so this cannot be a TOML variant of the existing example. The move is an `ec2/` (and later `slurm/`) launcher plus a recipe module next to the existing files, with its own venv script pinning v0.4.0, documented in the example's README as a separate version line.

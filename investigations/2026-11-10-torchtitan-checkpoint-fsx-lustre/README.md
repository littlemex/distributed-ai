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
scripts/sitecustomize.py     TC_DISABLE_DIRECT_IO=1 makes torch_checkpointing write without O_DIRECT
tasks/10-torchtitan-env.json   torchtitan v0.4.0 (commit 45e33cd) + PyTorch 2.15.0 (cu132) venv and a debug-model smoke run
tasks/20-ckpt-timing.json      4 recipes x 2 targets, torch_checkpointing with buffered writes, then the summary
```

## Run

```bash
cd ../2026-11-10-p5e-single-node-campaign
./3.run.sh 2026-11-10-torchtitan-checkpoint-fsx-lustre/tasks/10-torchtitan-env.json
./3.run.sh 2026-11-10-torchtitan-checkpoint-fsx-lustre/tasks/20-ckpt-timing.json
```

## Results

Measured on 2026-11-10 (p5e.48xlarge, sa-east-1). Raw records: [`results/p5e-2026-11-10/summary.md`](results/p5e-2026-11-10/summary.md). Each value is the median of the saves at steps 5, 10, 15 and 20 of one run; a full checkpoint is 96.4 GB. A training step without a save took 0.88 s in every run.

| Checkpointer | Target | Training stopped (s) | Checkpoint complete on storage (s) |
|---|---|---|---|
| DCP, synchronous | FSx for Lustre | 24.1 | 24.2 |
| DCP, async | FSx for Lustre | 5.5 | 34.2 |
| DCP, async with pinned memory | FSx for Lustre | 0.37 | 29.5 |
| torch_checkpointing, buffered writes | FSx for Lustre | 4.0 | 51.8 |
| DCP, synchronous | local NVMe RAID0 | 10.2 | 10.2 |
| DCP, async | local NVMe RAID0 | 5.5 | 18.1 |
| DCP, async with pinned memory | local NVMe RAID0 | 0.18 | 15.3 |
| torch_checkpointing, buffered writes | local NVMe RAID0 | 3.9 | 22.2 |

- Asynchronous saving cut the time a save itself stopped training from 24 s to 0.37 s on FSx for Lustre; the checkpoint was on storage 30 to 34 s after the save started, later than with the synchronous save, because the write runs while training continues.
- That did not make training faster here. torchtitan waits for the previous save to finish before it starts the next one (`maybe_wait_for_saving`), and with a save every 5 steps (about 4.4 s of compute) the 25 to 30 s write could not be hidden. Steps 6 to 20, which include three saves, took:

  | Checkpointer | FSx for Lustre | local NVMe RAID0 |
  |---|---|---|
  | DCP, synchronous | 60.7 s | 32.9 s |
  | DCP, async | 73.7 s | 39.5 s |
  | DCP, async with pinned memory | 64.9 s | 36.2 s |
  | torch_checkpointing, buffered writes | 55.6 s | 25.8 s |

  The "training stopped" column above excludes that wait. Asynchronous saving pays off when the compute between saves is longer than the write, which is the normal case for intervals of tens of minutes.
- For torch_checkpointing, "training stopped" is the time from `Initiating checkpoint staging` to `Staging copy done.` and "complete" is when the step directory appeared (the library writes to a temporary directory and renames it).
- torch_checkpointing 0.1.1 with its default settings failed on both targets: its file writer opens files with `O_DIRECT` and falls back to buffered I/O only if `open()` refuses, but the unaligned writes that follow fail with `EINVAL` (`[enforce fail at inline_container.cc:671] unexpected pos 64 vs 0`). The buffered rows set `TC_DISABLE_DIRECT_IO=1`, which `scripts/sitecustomize.py` turns into `use_direct_io=False` in every process, including the library's writer subprocess.
- The 8B recipe uses flex attention. torchtitan's default varlen backend imports FlashAttention 3 (`flash_attn_interface`), which `requirements.txt` does not install, and v0.4.0 no longer accepts `sdpa` for language models.

## Scope

One node shows the mechanism, not the scale behaviour: at 512 GPUs the aggregate write bandwidth and the barrier costs differ. The 4.8 TiB file system is the smallest EFA-enabled size and caps aggregate throughput near 4.8 GB/s.

## Contributing upstream

`examples/training/torchtitan/` in awsome-distributed-ai pins torchtitan v0.2.2 and has only a Slurm launcher with checkpointing disabled. torchtitan v0.4.0 replaced the TOML configuration with Python recipes, so this cannot be a TOML variant of the existing example. The move is an `ec2/` (and later `slurm/`) launcher plus a recipe module next to the existing files, with its own venv script pinning v0.4.0, documented in the example's README as a separate version line.

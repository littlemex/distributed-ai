# Results — UCCL-EP dispatch/combine on EFA (p5en x2, EP16)

Raw logs (evidence, one file per run):
- normal mode: `results/internode_normal_rank0_run{1,2,3}.log`
- low-latency mode: `results/lowlatency_rank0_run{1,2,3}.log`
- earlier 2026-07-20 run kept for history: `results/*_prev20260720.log`

Machine-readable: `results/summary.json`.

## Headline

Token-granular MoE dispatch/combine all-to-all **completed correctly over AWS
EFA with no `nvidia_peermem`**, using UCCL-EP's dma-buf GPUDirect path. DeepEP
cannot run on EFA, so there is no apples-to-apples baseline on this hardware —
running at all, at a usable fraction of line rate, is the result.

This was reproduced across **three fresh runs per mode (2026-07-28)** plus the
earlier 2026-07-20 run. normal mode is highly repeatable; low-latency mode has a
stable end-to-end figure but a run-to-run-variable dispatch/combine split (see
below). All numbers below are rank 0.

At bench startup the GPU-memory registration path is confirmed:

```
can_reg: True          # ep.can_register_rdma_gpu_buffer(0, 64MiB)
host_allocated: False  # ep.get_rdma_buffer(...) -> real GPU buffer, not host fallback
```

## normal mode (`test_internode.py`, 4096 tok / hidden 7168 / top-8 / 256 exp)

RDMA = inter-node EFA path; NVL = intra-node NVLink. GB/s, rank 0, best chunk
config (the bench sweeps SM count / NVL chunk / RDMA chunk internally).

| op | 07-20 | run1 | run2 | run3 | range (RDMA) |
|----|------:|-----:|-----:|-----:|-------------:|
| dispatch BF16 — RDMA | 41.28 | 41.32 | 41.75 | 42.88 | 41.3–42.9 |
| dispatch BF16 — NVL  | 134.74 | 134.88 | 136.27 | 139.97 | — |
| dispatch FP8 — RDMA  | 38.94 | 38.87 | 39.17 | 39.22 | 38.9–39.2 |
| dispatch FP8 — NVL   | 127.11 | 126.87 | 127.86 | 128.02 | — |
| combine — RDMA       | 18.04 | 17.26 | 18.36 | 18.68 | 17.3–18.7 |
| combine — NVL        | 58.89 | 56.33 | 59.92 | 60.98 | — |

Repeatable to within ~2% across all four runs. per-GPU EFA = 400 Gbps ≈ 50 GB/s
→ dispatch reaches ~82–86% of per-GPU line rate. combine < dispatch is expected
(asymmetric gather-back pattern; same trend in the UCCL blog).

## low-latency mode (`test_low_latency.py`, 128 tok / hidden 7168 / top-8 / 256 exp)

Settings: `return_recv_hook=False dispatch_use_fp8=False`. GB/s, rank 0.

| metric | 07-20 | run1 | run2 | run3 |
|--------|------:|-----:|-----:|-----:|
| dispatch+combine (end-to-end) | 16.64 | 16.78 | 16.52 | 16.99 |
| end-to-end avg_t (us)         | 1324.8 | 1313.8 | 1334.6 | 1297.9 |
| dispatch (measured alone)     | 20.21 | 7.58 | 8.73 | 19.20 |
| combine (measured alone)      | 30.80 | 57.63 | 50.48 | 31.97 |

**Read this carefully — the split is not stable.** The end-to-end
dispatch+combine bandwidth is steady across all four runs (16.5–17.0 GB/s,
±1.4%). But when dispatch and combine are timed *separately*, the split swings
hard and *inversely*: runs where dispatch measures low (7.6–8.7 GB/s) are the
same runs where combine measures high (50–58 GB/s), and vice-versa. The
low-latency kernel overlaps the two phases and the per-phase boundary lands
differently each run, so the standalone dispatch/combine figures are **not**
reliable point values — only the end-to-end number is representative.

The earlier 07-20 result (dispatch 20.21 / combine 30.80) is the *same shape* as
run3 (dispatch-high / combine-low); it was one end of this variance, **not an
outlier**. Do not quote a single-run dispatch or combine low-latency number as if
it were the figure.

## Not a comparison

UCCL's blog reports **EP32** on p5en (dispatch 54 / combine 43 GB/s). This run is
**EP16** (2 nodes only), a different number of peers, so the numbers are **not
directly comparable**. We do not claim parity with DeepEP (which does not run on
EFA) or with the blog's EP32 figures.

## Scope / limits

- EP16 only (2 nodes). Microbenchmark only — no slime/SGLang/vLLM end-to-end.
- 3 runs per mode (2026-07-28) + 1 earlier run (2026-07-20). Within each run the
  bench sweeps chunk sizes internally and reports the best.
- normal mode: repeatable to ~2%. low-latency mode: end-to-end repeatable to
  ~1.4%, but the standalone dispatch vs combine split is run-dependent (above).

# Results — UCCL-EP dispatch/combine on EFA (p5en x2, EP16)

Raw logs: `results/internode_normal_rank0.log`, `results/lowlatency_rank0.log`.
Machine-readable: `results/summary.json`.

## Headline

Token-granular MoE dispatch/combine all-to-all **completed correctly over AWS
EFA with no `nvidia_peermem`**, using UCCL-EP's dma-buf GPUDirect path. DeepEP
cannot run on EFA, so there is no apples-to-apples baseline on this hardware —
running at all, at a usable fraction of line rate, is the result.

At bench startup the GPU-memory registration path is confirmed:

```
can_reg: True          # ep.can_register_rdma_gpu_buffer(0, 64MiB)
host_allocated: False  # ep.get_rdma_buffer(...) -> real GPU buffer, not host fallback
```

## normal mode (`test_internode.py`, 4096 tok / hidden 7168 / top-8 / 256 exp)

| op | RDMA (inter-node EFA) | NVLink (intra-node) |
|----|----------------------:|--------------------:|
| dispatch (BF16) | 41.28 GB/s | 134.74 GB/s |
| dispatch (FP8)  | 38.94 GB/s | 127.11 GB/s |
| combine (BF16)  | 18.04 GB/s | 58.89 GB/s |

per-GPU EFA = 400 Gbps ≈ 50 GB/s → dispatch reaches ~82% of per-GPU line rate.
combine < dispatch is expected (asymmetric gather-back pattern; same trend in the
UCCL blog).

## low-latency mode (`test_low_latency.py`, 128 tok / hidden 7168 / top-8 / 256 exp)

| metric | value (rank 0) |
|--------|---------------:|
| dispatch | 20.21 GB/s, avg 371.6 us |
| combine  | 30.80 GB/s, avg 471.9 us |
| dispatch + combine | 16.64 GB/s, avg 1324.8 us |

## Not a comparison

UCCL's blog reports **EP32** on p5en (dispatch 54 / combine 43 GB/s). This run is
**EP16** (2 nodes only), a different number of peers, so the numbers are **not
directly comparable**. We do not claim parity with DeepEP (which does not run on
EFA) or with the blog's EP32 figures.

## Scope / limits

- EP16 only (2 nodes). Microbenchmark only — no slime/SGLang/vLLM end-to-end.
- Single run per mode; the bench sweeps chunk sizes internally and reports the
  best, but we did not repeat the whole job for run-to-run variance.

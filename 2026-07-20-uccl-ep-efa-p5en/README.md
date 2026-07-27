# UCCL-EP on AWS EFA (p5en / H200 x16) — microbenchmark verification

This directory verifies that **UCCL-EP** — a portable expert-parallel (MoE
dispatch/combine) communication library — runs on **AWS EFA**, where DeepEP
(which depends on NVIDIA IBGDA) does not.

## Why this matters

MoE models route each token to a small set of experts that live on different
GPUs. The `dispatch` (send tokens to their experts) and `combine` (gather
results back) steps are an **all-to-all** and become the communication
bottleneck. DeepEP makes this fast with **GPU-initiated, token-granular RDMA**,
but it is bound to NVIDIA GPU + NVIDIA NIC via **IBGDA**, so it does not run on
AWS EFA.

UCCL-EP keeps the GPU-initiated *command* path but moves the NIC-facing work to
a **multi-threaded CPU proxy** built on the portable `libibverbs`/`efadv` verbs
API. That is what lets the same `deep_ep`-compatible interface run over EFA.

## Scope (honest limits)

- **EP16 only.** This cluster is `p5en x2` = 16 GPUs, so we can reach EP16 at
  most. The UCCL blog's headline numbers are **EP32**; we cannot reproduce those
  and do **not** compare against them directly.
- **Microbenchmark only.** We measure `dispatch`/`combine` bandwidth and latency
  (`bench/test_internode.py`, `bench/test_low_latency.py`). No slime/SGLang
  end-to-end workload here.
- **No DeepEP baseline.** DeepEP does not run on EFA, so there is no apples-to-
  apples baseline on this hardware. NCCL all-to-all is shown only as a rough
  scale reference, not a "beat DeepEP" claim.

The point we set out to prove is narrow and concrete: **token-granular
dispatch/combine all-to-all completes correctly over EFA and sustains a usable
fraction of the per-GPU line rate.**

## Layout

```
2026-07-20-uccl-ep-efa-p5en/
  manifests/   kubernetes manifests (probe pod, 2-node bench job)
  scripts/     build-uccl.sh (USE_DMABUF build) + run-bench.sh (kubectl wrapper)
  docs/        results write-up (RESULTS.md), build/run gotchas (GOTCHAS.md)
  results/     captured logs (one per run) + parsed metrics (summary.json)
```

`results/` holds 3 runs per mode from 2026-07-28
(`*_run{1,2,3}.log`) plus the earlier 2026-07-20 run (`*_prev20260720.log`),
kept as evidence. See `docs/RESULTS.md` for the reproducibility/variance summary.

## Environment (this run)

- Cluster: EKS, 2x `p5en.48xlarge` (H200 x8 each = 16 GPU), reserved (Capacity Block).
- Per-node EFA: 16 cards total; schedulable `vpc.amazonaws.com/efa = 15` (card 0
  carries the node IP and is not advertised as EFA).
- Exact cluster name / account / region are environment-specific and kept out of
  this doc; see the team connection notes.

## References (primary sources)

- Blog: https://uccl-project.github.io/posts/uccl-ep-full/
- Code: https://github.com/uccl-project/uccl/tree/main/ep
- Paper: arXiv:2512.19849

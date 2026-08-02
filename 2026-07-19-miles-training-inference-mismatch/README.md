# miles Training-Inference Mismatch on Amazon EKS

GRPO post-training with [miles](https://github.com/radixark/miles) (a CUDA-13 / Blackwell
fork of [SLIME](https://github.com/THUDM/slime)) on Amazon EKS, reproducing the
training-inference mismatch study from the sibling
[`2026-07-19-slime-training-inference-mismatch`](../2026-07-19-slime-training-inference-mismatch)
on a second, independent RL framework.

## Layout (two layers)

```
2026-07-19-miles-training-inference-mismatch/   # repo-local, date-prefixed record
├── 3.test_cases/pytorch/miles/                 # upstream-shaped tree (mirrors awsome-distributed-ai's slime test case)
│   └── README.md                               # the actual test-case doc + Verification Status + concordance
└── local-overlays/                             # NOT for upstream: borrowed-cluster-specific overrides
```

The inner `3.test_cases/pytorch/miles/` directory is arranged exactly like
awsome-distributed-ai's `3.test_cases/pytorch/slime/`, so it can be lifted into a future
upstream contribution as-is. Start at
[`3.test_cases/pytorch/miles/README.md`](./3.test_cases/pytorch/miles/README.md).

`local-overlays/` holds environment-specific overrides (a head-on-GPU RayCluster overlay
used because the borrowed validation cluster had no large-disk CPU node). It is
deliberately kept outside the upstream tree and must not be part of the contribution.

## Status

Validated on H200x8 (single node and 2-node/16-GPU over EFA) and on p5/H100x8. Verified:
Qwen3-4B colocated GRPO, Qwen3-30B-A3B MoE colocated on 16 GPU, the KV-fp8 collapse arm and
the TIS rescue arm, **3-seed variance on collapse/rescue**, per-kernel attribution of the
amplification, and **SGLang-vs-vLLM cross-engine concordance**. Still `UNVERIFIED`: 30B MoE
*disaggregated* (needs B300 HBM), the disaggregated reward service, and multi-seed variance
on the baseline / 30B tables. See the Verification Status table in the inner README and
[`docs/RESULTS.md`](./3.test_cases/pytorch/miles/docs/RESULTS.md).

## Headline result

miles reproduces the slime findings on the same hardware and hyperparameters: baseline
`mis_kl` 0.000632 (slime ~0.00065), KV-fp8 amplification to 0.0310 / ~49x (slime ~54x),
and `ppo_kl` 0.0 at dropout=0. Because the two images pin different SGLang versions, this
is a concordance study rather than a bit-exact comparison -- agreement across that gap is
evidence the phenomenon is framework-independent and set by the rollout/trainer
numerical-path difference. Details:
[`3.test_cases/pytorch/miles/docs/RESULTS.md`](./3.test_cases/pytorch/miles/docs/RESULTS.md).

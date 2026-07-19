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

Validated on a **single H200x8 node only**. The verified path is Qwen3-4B colocated GRPO
(1 step); multi-node, MoE-disaggregated, TIS rescue, and the disaggregated reward service
are mirrored from slime but marked `UNVERIFIED`. See the Verification Status table in the
inner README.

## Headline result

miles reproduces the slime findings on the same hardware and hyperparameters: baseline
`mis_kl` 0.000632 (slime ~0.00065), KV-fp8 amplification to 0.0310 / ~49x (slime ~54x),
and `ppo_kl` 0.0 at dropout=0. Because the two images pin different SGLang versions, this
is a concordance study rather than a bit-exact comparison -- agreement across that gap is
evidence the phenomenon is framework-independent and set by the rollout/trainer
numerical-path difference. Details:
[`3.test_cases/pytorch/miles/docs/RESULTS.md`](./3.test_cases/pytorch/miles/docs/RESULTS.md).

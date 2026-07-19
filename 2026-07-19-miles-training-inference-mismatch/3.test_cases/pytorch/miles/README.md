# Reinforcement Learning with miles on Amazon EKS (Training-Inference Mismatch study)

This test case runs GRPO post-training with [miles](https://github.com/radixark/miles) --
a direct fork of [SLIME](https://github.com/THUDM/slime) targeting CUDA 13 and NVIDIA
Blackwell as first-class -- on Amazon EKS, and reproduces the training-inference
**mismatch** study from the sibling
[slime test case](../slime/) (arXiv:2602.01826). It mirrors the slime test case
structure so the two can be compared side by side.

miles integrates the same two backends as slime -- **SGLang** (rollout / inference) and
**Megatron-LM** (training) -- coordinated by **Ray**, in colocated or disaggregated
topologies. The train loop is rewritten sync -> async, but the `train.py` CLI and the
mismatch-measurement flags are compatible with slime (verified on hardware).

> This directory is a hardware-validation record intended as the basis for a future
> upstream `3.test_cases/pytorch/miles/` contribution to awsome-distributed-ai. It was
> validated on a **single H200x8 node only**. Components that mirror slime but were not
> executed on this hardware are marked `UNVERIFIED`; see the Verification Status table.

## Verification Status

| Component | Status | Environment / Note |
|-----------|--------|--------------------|
| Qwen3-4B GRPO, colocated, 1 step | Verified | H200x8 single node; rollout + weight sync + Megatron backward |
| mismatch metrics (baseline) | Verified | mis_kl 0.000632 (matches slime ~0.00065) |
| KV fp8 mismatch amplification | Verified | mis_kl 0.0310 (~49x baseline; matches slime's ~54x) |
| ppo_kl = dropout artefact (both arms) | Verified | ppo_kl 0.0 at dropout=0, 0.30 at dropout=0.1; mis_kl unchanged (matches slime) |
| miles image build (radixark/miles + EFA) | Verified | in-cluster buildkit -> ECR, 18.4GB |
| RayCluster with head on a CPU node | UNVERIFIED | the shipped `raycluster.yaml` puts the head on a CPU node; the actual runs used the head-on-GPU overlay in `local-overlays/` because the borrowed cluster had no large-disk CPU node. The GRPO results are valid; only this head-placement variant of the manifest is untested. |
| 2-node EFA (16 GPU NCCL) | Verified | busbw 190-257 GB/s over EFA (efa-direct + GPUDirect RDMA, no TCP fallback); see docs/EFA_2NODE.md. Required fixing a self-referencing egress gap in the EFA security group |
| Multi-seed variance | UNVERIFIED | attempted; the p5en node went NotReady (EC2 impaired) mid-run. Results stay single-seed point estimates |
| Collapse + TIS rescue on miles | UNVERIFIED | slime showed collapse at step 14-18 and TIS rescue; miles run cut short by the same node fault |
| TIS rescue arm | UNVERIFIED | `env_vars.tis.example`; flags exist, run not executed |
| Multi-node (>=2 nodes) | UNVERIFIED | single node only |
| Qwen3-30B-A3B MoE, disaggregated | UNVERIFIED | `recipe/run_grpo_qwen3_30b_a3b.sh` mirrors slime; not executed |
| Disaggregated reward (remote_rm on CPU pool) | UNVERIFIED | `reward_service/`, `kubernetes/reward-service.yaml`; miles remote_rm lacks slime's retry |
| Checkpoint convert / long run | Known Issue | `save_model()` fails with `_pickle.UnpicklingError`; see Known Issues |

Files that were mirrored from slime but not exercised on miles carry a
`# STATUS: UNVERIFIED` comment at the top.

## Two-framework concordance (slime vs miles)

This is a **concordance study**: the slime and miles numbers below were measured on the
**same physical cluster** (one H200x8 node) with the same model and hyperparameters, and
they agree. Two caveats keep this honest:

- **miles is a direct fork of slime**, not an independent reimplementation. The two share
  most of the Megatron/SGLang integration code, so agreement is weaker evidence than two
  independent implementations agreeing -- a shared-code origin for the match cannot be
  ruled out. Read the result as *fork-level concordance*, not proof of framework
  independence.
- The two images pin **different SGLang versions** (0.5.12.post1 vs 0.5.16.dev), and
  `mis_kl` depends on the inference kernel, so this is not a bit-exact comparison. That
  the numbers agree *across* that version gap is a modest robustness signal, not a proof.

### Fixed conditions (identical in both)

Same cluster and **GPU (H200x8, single node)**; model Qwen3-4B dense; dataset
dapo-math-17k; GRPO hyperparameters (eps-clip, KL coef); `--seed 1234 --rollout-seed 42`;
rollout length 8192; temperature 1.0; `--attention-dropout 0 --hidden-dropout 0`;
TP1/PP1/CP1/EP1, colocated.

### Known non-equivalent axes (could not be held equal)

| Axis | slime | miles |
|------|-------|-------|
| SGLang | 0.5.12.post1 | 0.5.16.dev |
| Base image | NGC pytorch 26.02 (CUDA 13.1) | radixark/miles (nvidia/cuda 13.0.1) |
| weight sync | slime engine wrapper | miles engine wrapper (Ray actor methods) |

### Measured values (same cluster, single seed, point estimates)

| Metric | slime | miles | Concordance |
|--------|-------|-------|-------------|
| baseline mis_kl (LR 1e-6, dropout 0) | 0.00065 | 0.000632 | same order (~3% apart) |
| KV fp8 mis_kl (see LR note) | 0.0327 (~54x) | 0.0310 (~49x) | same direction & order |
| ppo_kl at dropout 0 | 0.0 | 0.0 | both zero |
| ppo_kl at dropout 0.1 | 0.31 | 0.30 | both ~0.30 (dropout artefact) |

LR note: the baseline runs at LR 1e-6 and the KV fp8 runs at LR 1e-5, so the "~49x/~54x"
figure varies dtype and LR together. `mis_kl` at step 0 is a property of the
rollout-vs-train numerical path (before any optimizer step diverges the policies), so LR
does not drive the step-0 amplification; both frameworks were compared under the identical
LR pairing, so the concordance holds even though the amplification factor itself is not a
clean single-variable attribution.

Caveat: **single seed, point estimates** (baseline reported at step 0; KV fp8 observed
over the first few steps). Variance not evaluated. Running 3 seeds would strengthen the
claim (not done -- single borrowed GPU node with a fixed capacity-block window).

Full numbers: [docs/RESULTS.md](./docs/RESULTS.md). Framework port details and the
pitfalls found on real hardware: [docs/PORT_NOTES.md](./docs/PORT_NOTES.md).

## Hardware validated

| Component | Specification |
|-----------|---------------|
| Instance type | p5en.48xlarge (this study) |
| Nodes | 1 (single-node only -- multi-node UNVERIFIED) |
| GPUs | 8x NVIDIA H200 |
| Storage | FSx for Lustre, mounted as PVC `fsx-claim` |
| Kubernetes | EKS v1.35, KubeRay operator |

The slime test case targets 2x p5.48xlarge (H100x16). This study used a single
H200x8 node, so anything requiring more than one node is UNVERIFIED.

## Quick Start (Qwen3-4B colocated -- the verified path)

Prerequisites: KubeRay operator installed; FSx PVC `fsx-claim`; a **CPU NodePool** for
the Ray head (see Infra note below); models/data staged on FSx.

> Note: the GRPO results in this test case were produced with the head on a GPU node
> (the `local-overlays/` overlay), because the validation cluster had no large-disk CPU
> node. The `raycluster.yaml` shipped here uses the recommended head-on-CPU placement,
> which is the correct production shape but was not itself run end-to-end -- see the
> Verification Status table.

```bash
# 0. Configure env
cp env_vars.colocated.example env_vars && vim env_vars   # set HF_TOKEN, paths

# 1. Build + push the miles image (GPU not needed; runs on a large-disk node)
#    Edit kubernetes/buildkit-job.yaml nodeSelector to a node with >=120GB ephemeral.
kubectl apply -f kubernetes/buildkit-job.yaml

# 2. Stage mismatch configs on FSx
#    configs/{mis.yaml,mis_metrics_only.yaml,mis_nocap.yaml} -> /fsx/configs/

# 3. Deploy the Ray cluster (head on a CPU node, worker on the GPU node)
envsubst < kubernetes/raycluster.yaml | kubectl apply -f -

# 4. Launch GRPO. The driver MUST run on a GPU worker (miles imports mooncake,
#    which needs libcuda, at module load): route it there with a custom resource.
ray job submit \
  --entrypoint-resources '{"gpu_node": 0.001}' \
  --working-dir recipe \
  -- bash grpo_launch.sh <train.py flags from env_vars>
```

See the slime test case README for the full 8-step workflow (model download, HF->Megatron
conversion, reward configuration); the miles steps are identical except for the paths and
the two miles-specific requirements below.

## miles-specific requirements (found on real hardware)

Three issues surface on the miles base image (nvidia/cuda) that do NOT occur on slime's
NGC base. All are fixed in this test case's `miles.Dockerfile` / manifests; details and
evidence in [docs/PORT_NOTES.md](./docs/PORT_NOTES.md).

1. **CUDA compat shadowing (Error 803)** -- the base ships an older forward-compat
   libcuda than the node driver; `miles.Dockerfile` removes it and uses the host driver.
2. **libcuda.so.1 not found in the SGLang subprocess** -- driver-injection dirs
   (`/usr/lib64`, `/usr/lib/x86_64-linux-gnu`) are appended to `LD_LIBRARY_PATH` and
   registered with `ldconfig`.
3. **Ray job driver dies on the head (no libcuda)** -- miles imports `mooncake`
   (libcuda-dependent) at module load. The head is a non-GPU pod. The worker declares a
   `gpu_node` custom resource and the job is submitted with
   `--entrypoint-resources '{"gpu_node": 0.001}'`, so the driver runs on a GPU worker
   without consuming a GPU (does not conflict with the colocated 8-GPU placement group).

## Infra note (Ray head placement)

The Ray head is a non-GPU pod but must pull the ~18GB miles image, so its node needs
ample `ephemeral-storage`. This test case pins the head to `nodeSelector: node-role: cpu`
and requests `ephemeral-storage: 40Gi`, so a too-small node is rejected (Pending) rather
than silently Evicted mid-pull.

This assumes the CPU node's root EBS is large enough. Provision the CPU pool's root
volume at **150Gi or more** for RL workloads: a ~18GB image needs ~40GB during pull
(compressed + extracted layers) plus head logs / GCS / object spilling, and a 50Gi root
volume will Evict the head mid-pull. (If you manage the cluster with the sibling
`infra/eks` Terraform in this repo, this is the `cpu_node_volume_size` variable -- no code
change needed, just override the value.)

## Known Issues

1. **`save_model()` fails with `_pickle.UnpicklingError: pickle data was truncated`.**
   Occurs in Megatron's distributed checkpoint save (`gather_object`) after the training
   step completes; the GRPO loop itself is unaffected. Surfaced when `num-rollout 1`
   triggers a final auto-save. Long runs that must checkpoint, and the HF<->Megatron
   `scripts/convert_checkpoint.sh` round-trip, are therefore untested on miles. Workaround
   for smoke tests: raise `SAVE_INTERVAL` beyond the step count to skip saving.

## File Structure

```
miles/                                   # -> 3.test_cases/pytorch/miles (upstream target path)
├── README.md                           # This file (Verification Status + concordance + workflow)
├── miles.Dockerfile                    # radixark/miles base + EFA layer (strategy C)
├── requirements.txt                    # [UNVERIFIED] reference; miles bundles deps in the base image
├── env_vars.colocated.example          # Verified: Qwen3-4B colocated baseline (measurement-only)
├── env_vars.amplified.example          # Verified: KV fp8 mismatch amplification
├── env_vars.tis.example                # [UNVERIFIED] TIS rescue arm
├── env_vars.disaggregated.example      # [UNVERIFIED] disaggregated reward overlay
├── configs/                            # mismatch metric configs (mis / mis_metrics_only / mis_nocap)
├── reward_service.Dockerfile           # [UNVERIFIED] CPU reward image (mirrors slime)
├── reward_service/{app.py,requirements.txt}   # [UNVERIFIED] FastAPI reward server
├── kubernetes/
│   ├── buildkit-job.yaml               # in-cluster image build -> ECR (CPU-only, GPU-free)
│   ├── raycluster.yaml                 # KubeRay cluster (head=CPU node, worker=GPU + gpu_node resource)
│   ├── reward-service.yaml             # [UNVERIFIED] CPU reward Deployment + Service
│   └── data-prep-pod.yaml              # [UNVERIFIED] data-prep utility pod
├── recipe/
│   ├── run_grpo_qwen3_4b.sh            # Verified: GRPO submit (Qwen3-4B colocated)
│   ├── run_grpo_qwen3_30b_a3b.sh       # [UNVERIFIED] MoE disaggregated (mirrors slime)
│   └── launcher/grpo_launch.sh         # Ray job entrypoint (SLIME_DIR -> /root/miles)
├── scripts/
│   ├── convert_checkpoint.sh           # [UNVERIFIED] HF<->Megatron (see Known Issues)
│   └── evaluate.sh                     # [UNVERIFIED] evaluation launcher
└── docs/
    ├── RESULTS.md                      # miles measurements + slime comparison
    └── PORT_NOTES.md                   # port details + the 3 hardware pitfalls

local-overlays/                         # NOT for upstream: borrowed-cluster-specific overlay
                                        # (head-on-GPU hack for a cluster without a large CPU node)
```

`local-overlays/` is one level outside the upstream tree on purpose: it holds the
environment-specific head-on-GPU overlay used to run this study on a borrowed cluster
that lacked a large-disk CPU node. It must not be part of the upstream contribution.

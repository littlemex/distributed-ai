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
> upstream `3.test_cases/pytorch/miles/` contribution to awsome-distributed-ai. The core
> mismatch study (baseline / KV fp8 / dropout arms) was validated on a **single H200x8
> node**; the 4B and 30B-MoE GRPO loops were additionally validated **across 2 p5en nodes
> (16 GPU) over EFA** (colocated). Components that mirror slime but were not executed on
> this hardware are marked `UNVERIFIED`; see the Verification Status table.

## Verification Status

| Component | Status | Environment / Note |
|-----------|--------|--------------------|
| Qwen3-4B GRPO, colocated, 1 step | Verified | H200x8 single node; rollout + weight sync + Megatron backward |
| mismatch metrics (baseline) | Verified | mis_kl 0.000632 (dropout=0; same order as slime's dropout=0 0.00053, within slime's 0.00053-0.00074 run spread) |
| KV fp8 mismatch amplification | Verified | mis_kl 0.0310 (~49x baseline; matches slime's ~54x) |
| ppo_kl = dropout artefact (both arms) | Verified | ppo_kl 0.0 at dropout=0, 0.30 at dropout=0.1; mis_kl unchanged (matches slime) |
| miles image build (radixark/miles + EFA) | Verified | in-cluster buildkit -> ECR, 18.4GB |
| RayCluster with head on a CPU node | UNVERIFIED | the shipped `raycluster.yaml` puts the head on a CPU node; the actual runs used the head-on-GPU overlay in `local-overlays/` because the borrowed cluster had no large-disk CPU node. The GRPO results are valid; only this head-placement variant of the manifest is untested. |
| 2-node EFA (16 GPU NCCL) | Verified | busbw 190-257 GB/s over EFA (efa-direct + GPUDirect RDMA, no TCP fallback); see docs/EFA_2NODE.md. Required fixing a self-referencing egress gap in the EFA security group |
| Qwen3-4B GRPO, colocated, 2 nodes (16 GPU), 3 cycles | Verified | actor 2x8 + rollout 16 over EFA; 3 rollouts SUCCEEDED (raw_reward 0.48/0.52/0.49); see docs/RESULTS.md |
| Qwen3-30B-A3B MoE, colocated, 2 nodes (16 GPU) -- completes without OOM/crash | Verified | actor 2x8 + `--use-distributed-optimizer` + triton EP2; the rollout/train cycle completes. This row is about the layout fitting and running, nothing more |
| Qwen3-30B-A3B MoE -- produces a usable measurement | **Known Issue** | across 4 independent runs generation falls into a repetition loop and never reaches an answer (`repetition_frac` 0.48-0.70, `truncated` 0.97-0.99, `raw_reward` 0.0). The `mis_kl` these runs report is therefore a measurement of repetition, not of train/rollout mismatch, and is marked UNUSABLE in the data ledger. Root cause unresolved -- see `experiment/h200_results/P2R_30B_INVALID.md` |
| Multi-seed variance | UNVERIFIED | attempted; the p5en node went NotReady (EC2 impaired) mid-run. Results stay single-seed point estimates |
| KV fp8 collapse arm (no TIS) | Verified | driven to divergence: mis_kl 0.033 -> 2.10, grad_norm 0.22 -> 14.3 over 25 steps; matches slime's step-14-18 collapse. See docs/RESULTS.md |
| TIS rescue arm (through collapse) | Verified | `env_vars.tis.example`, 30 steps: with TIS, mis_kl stays ~0.03-0.045 and grad_norm ~0.11-0.22 throughout -- no divergence, vs the no-TIS arm's mis_kl 2.10 / grad_norm 14.3 at step 24. See docs/RESULTS.md |
| Multi-node (>=2 nodes) | Verified | 4B + 30B MoE both ran colocated on 2 p5en nodes (16 GPU) over EFA |
| Qwen3-30B-A3B MoE, disaggregated | UNVERIFIED | verified as **colocated 16 GPU** (fits H200 141GB with distributed optimizer); the disaggregated actor-8 layout needs B300 288GB and is not run here |
| 30B slime-vs-miles clean pairing | **Withdrawn** | the mis_kl values this row once quoted (0.00182/0.00192) are not backed by any run: see "Withdrawn numbers" below. The 30B runs that do exist report mis_kl 0.196-0.839 and are UNUSABLE (repetition loop). The framework comparison stands on the 4B dense pairing only |
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
| baseline mis_kl (4B, dropout 0) | 0.00053 | 0.000632 | same order (within slime's 0.00053-0.00074 run spread; the 0.00065 quoted elsewhere is slime's dropout=0.1 run) |
| KV fp8 mis_kl (4B, see LR note) | 0.0327 (~54x) | 0.0310 (~49x) | same direction & order |
| ppo_kl at dropout 0 (4B) | 0.0 | 0.0 | both zero |
| ppo_kl at dropout 0.1 (4B) | 0.31 | 0.30 | both ~0.30 (dropout artefact) |
### Withdrawn numbers

An earlier version of this table reported a 30B MoE row: `mis_kl` 0.00182 (slime) against
0.00192 (miles), described as "same order" and used to claim the framework concordance held
at MoE scale as well as at 4B. **No run produced those values.** They were retracted when
every reported cell was cross-checked against the trainer's own TensorBoard event files; the
audit is `experiment/h200_results/DATA_STATUS.md` and the tool that performs it is
`experiment/verify_results.py`.

What the 30B runs actually report is `mis_kl` 0.196 to 0.839 across four runs -- two to three
orders of magnitude away from the withdrawn figures -- and every one of those runs fails the
step-0 sanity screen, because generation is already looping before the first optimizer step
(`repetition_frac` 0.48-0.70, `raw_reward` 0.0). So the real numbers cannot substitute for the
withdrawn ones either: at this configuration the 30B MoE `mis_kl` is measuring repetition
rather than train/rollout mismatch, and it is marked UNUSABLE rather than quoted.

**The framework concordance therefore rests on the 4B dense pairing alone.** It was not shown
at MoE scale, and this table no longer claims it was.

The 30B `ppo_kl` values were 0.0 on both frameworks, which is genuine but carries no
information here: `ppo_kl` is identically zero whenever dropout is 0 (see the dropout note
below), so it holds on a broken run exactly as it does on a healthy one.

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
| Nodes | 1 for the core mismatch arms; 2 (16 GPU, EFA) for the 4B + 30B-MoE GRPO loops |
| GPUs | 8x NVIDIA H200 per node |
| Storage | FSx for Lustre, mounted as PVC `fsx-claim` |
| Kubernetes | EKS v1.35, KubeRay operator |

The slime test case targets 2x p5.48xlarge (H100x16). The mismatch metric arms
(baseline / KV fp8 / dropout) were measured on a single H200x8 node; the 4B and 30B-MoE
GRPO loops were additionally run across 2 p5en nodes (16 GPU) over EFA.

## Quick Start (Qwen3-4B colocated -- the verified path)

Prerequisites: KubeRay operator installed; FSx PVC `fsx-claim`; a **CPU NodePool** for
the Ray head (see Infra note below); models/data staged on FSx.

> Note: the GRPO results in this test case were produced with the head on a GPU node
> (the `local-overlays/` overlay), because the validation cluster had no large-disk CPU
> node. The `raycluster.yaml` shipped here uses the recommended head-on-CPU placement,
> which is the correct production shape but was not itself run end-to-end -- see the
> Verification Status table.

```bash
# 0. Configure env FIRST, then create the HF Secret in that namespace so the pods
#    can mount it. Besides NAMESPACE/FSX_CLAIM, set GPU_NODE_ROLE to your GPU
#    NodePool's `node-role` label (p5en=gpu-p5en, p5/H100=gpu-p5, B300=gpu-b300)
#    and EFA_PER_NODE to the EFA cards to request per worker -- raycluster.yaml
#    substitutes both via envsubst, so the manifest is not pinned to one GPU type.
cp env_vars.colocated.example env_vars && vim env_vars   # NAMESPACE/FSX_CLAIM/GPU_NODE_ROLE/EFA_PER_NODE
source env_vars
kubectl create secret generic hf-token --from-literal=HF_TOKEN=hf_xxx -n "${NAMESPACE}"

# 1. Build + push the miles image (GPU not needed; runs on a large-disk node).
#    The pinned ECR tag must be built FROM THIS miles.Dockerfile (it deletes the
#    forward-compat libcuda that otherwise shadows the host driver -> torch.cuda
#    Error 803; see miles-specific requirement #1). buildkit-job.yaml needs two
#    prerequisites in the namespace first, or the Job fails ConfigMap/Secret-not-found:
#      kubectl create configmap miles-build-context \
#        --from-file=Dockerfile=miles.Dockerfile -n "${NAMESPACE}"
#      kubectl create secret docker-registry ecr-miles-push \
#        --docker-server="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com" \
#        --docker-username=AWS --docker-password="$(aws ecr get-login-password --region ${AWS_REGION})" \
#        -n "${NAMESPACE}"
#    Edit kubernetes/buildkit-job.yaml nodeSelector to a node with >=120GB ephemeral.
#    (If the pinned tag is already in ECR and built from the current Dockerfile,
#    skip this step -- the RayCluster pulls the tag directly.)
envsubst < kubernetes/buildkit-job.yaml | kubectl apply -f -   # ${FULL_IMAGE} from env_vars

# 2. Stage mismatch configs on FSx
#    configs/{mis.yaml,mis_metrics_only.yaml,mis_nocap.yaml} -> /fsx/configs/

# 3. Deploy the Ray cluster (head on a CPU node, worker(s) on the GPU node(s))
source env_vars
envsubst < kubernetes/raycluster.yaml | kubectl apply -f -

# 4. Port-forward the Ray dashboard (the recipe submits to 127.0.0.1:8265), then
#    launch GRPO via the recipe -- it sets --entrypoint-resources (driver on a GPU
#    worker; miles imports mooncake/libcuda at module load), the runtime env, and
#    the full train.py argv from env_vars.
kubectl port-forward -n "${NAMESPACE}" svc/miles-ray-head-svc 8265:8265 &
bash recipe/run_grpo_qwen3_4b.sh
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
│   ├── run_grpo_qwen3_4b.sh            # Verified: GRPO submit (Qwen3-4B colocated, 1 + 2 node)
│   ├── run_grpo_qwen3_30b_a3b.sh       # Verified: MoE colocated 16 GPU (disaggregated variant UNVERIFIED)
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

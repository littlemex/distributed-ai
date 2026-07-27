# hf-train-sample image

Minimal HuggingFace Trainer image used by the `pytorchjobTrain` (multi-node PyTorchJob) and
`torchrunTrain` (single-node, zero-operator) workloads in `charts/experiments`. It layers
`transformers`/`datasets`/`accelerate` and the training script on top of
`pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime` — nothing else.

## Why it is this small

The training runs under `torchrun`, either directly (single-node Job, `--standalone`) or under
a Kubeflow PyTorchJob. In the PyTorchJob case the Training Operator does not hand the container
`RANK` / `WORLD_SIZE` / `MASTER_ADDR` as plain pod env vars — a Worker-only job gets only the
torchrun-native `PET_*` variables, and the manifest's `spec.elasticPolicy` makes the operator
inject `PET_RDZV_BACKEND=c10d` plus `PET_RDZV_ENDPOINT=<job>-worker-0:23456`. `torchrun` reads
those, elects Worker-0 as the c10d rendezvous host, assigns node ranks dynamically, and then
re-exports `RANK` / `WORLD_SIZE` / `LOCAL_RANK` / `MASTER_ADDR` / `MASTER_PORT` into each
training process it spawns — which is where `train_smollm.py` reads them. Either way the image
needs no sshd, no Open MPI, and no `OMPI_*`→`torch.distributed` environment shim — the whole
SSH/mpirun apparatus that an MPIJob-based approach requires simply does not apply here. This is
why the image is just the PyTorch runtime plus the HF Trainer stack plus `train_smollm.py`.

## Build and push

```bash
ACCOUNT_ID=<your-account-id>
REGION=<your-region>          # must match the EKS cluster's region
REPO=hf-train-sample

aws ecr create-repository --region "$REGION" --repository-name "$REPO" \
  --image-scanning-configuration scanOnPush=true

aws ecr get-login-password --region "$REGION" \
  | finch login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# --platform linux/amd64 is required when building on Apple Silicon: EKS nodes are x86_64,
# and this Dockerfile is pure pip (prebuilt wheels, no compilation), so cross-building under
# finch's emulation is slow but reliable — expect a few minutes.
cd manifests/hf-train-sample
TAG=$(git rev-parse --short HEAD)
finch build --platform linux/amd64 -t "${REPO}:${TAG}" .
finch tag "${REPO}:${TAG}" "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO}:${TAG}"
finch push "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO}:${TAG}"
```

Use plain `docker` instead of `finch` if you have it; the commands are otherwise identical.
For continuous builds, `infra/ci` sets up a GitHub Actions workflow that builds this image on
push and pushes it to ECR via OIDC — this manual path is for local Dockerfile iteration.

## Verified facts (so you don't have to re-derive them)

- The `torchrun`/PyTorchJob path needs no SSH or MPI: `spec.elasticPolicy` makes the operator
  inject the c10d rendezvous endpoint (`PET_RDZV_BACKEND` / `PET_RDZV_ENDPOINT`), `torchrun`
  performs the rendezvous and re-exports `RANK`/`WORLD_SIZE`/`LOCAL_RANK`/`MASTER_ADDR`/
  `MASTER_PORT` into the training process, and `train_smollm.py` reads them directly (via
  `accelerate.PartialState`, which `TrainingArguments` delegates to).
- The EFS Access Point used for shared storage (`efs.tf`) enforces `posixUser` uid/gid 0. This
  image runs as root (uid 0), so writes to the mounted `/shared` are already owned correctly —
  no `chown` init container is needed (that step was only required by the earlier uid-1000
  image).

## Verification status

- **CPU (gloo), PyTorchJob, 2 Workers across 2 nodes** — verified on distai-eks-smoke
  (us-east-2, 2x r5a.large `cpu` pool). `torchrun` c10d rendezvous elected Worker-0, both
  Workers logged `[rank 0/2]` / `[rank 1/2]` with `backend=gloo`, the HF Trainer ran with a
  synchronized `grad_norm` across ranks, and the job reached Succeeded with the final model
  saved to the shared EFS mount by rank 0. A non-host Worker whose peer's image pull lagged hit
  one `OnFailure` restart and then re-rendezvoused (this is why `restartPolicy: OnFailure`, not
  `Never`).
- **GPU (nccl), PyTorchJob** — reviewed but NOT yet exercised on a GPU cluster. The manifest
  renders to valid YAML, but the NCCL path itself is unproven here.

## Known limitations / before you scale up

- **Single GPU per Worker assumed.** `train_smollm.py` does not map `LOCAL_RANK` to a CUDA
  device, so multi-GPU-per-node needs a `CUDA_VISIBLE_DEVICES`/device-assignment change plus a
  matching `nprocPerNode` / `gpu.count` bump (documented in the PyTorchJob manifest header).
- **Image is pinned by tag, not digest** (`pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime`).
  Fine for a sample; pin by digest for production.

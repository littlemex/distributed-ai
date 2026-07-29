# ddp-sample image

Minimal DistributedDataParallel image used by the `pytorchjobTrain` (multi-node PyTorchJob) and
`torchrunTrain` (single-node, zero-operator) workloads in `charts/experiments`. It trains an
MNIST MLP with `torch.nn.parallel.DistributedDataParallel` on top of
`pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime` — and nothing else: `torch` and `torchvision`
both ship in that base image, so there is not a single extra pip layer.

`ddp.py` is adapted from awsome-distributed-ai's `3.test_cases/pytorch/ddp/ddp.py`. Rendezvous
matches the awsome reference (etcd, via the PyTorchJob's `elasticPolicy`); the two deliberate
differences from that upstream sample are documented at the top of `ddp.py`: MNIST data +
snapshot on the shared PVC mount (rank 0 downloads, the rest read), and a rank-0-only snapshot
write. mlflow is optional (lazy import, only when `USE_MLFLOW=1`), so it is not baked into the
image. The one image dependency added over the base is `python-etcd` (the etcd rendezvous
client torch needs but does not bundle).

## Why it is this small

The training runs under `torchrun`, either directly (single-node Job, `--standalone`) or under
a Kubeflow PyTorchJob. In the PyTorchJob case the Training Operator does not hand the container
`RANK` / `WORLD_SIZE` / `MASTER_ADDR` as plain pod env vars — a Worker-only job gets only the
torchrun-native `PET_*` variables, and the manifest's `spec.elasticPolicy` makes the operator
inject `PET_RDZV_BACKEND=etcd` plus `PET_RDZV_ENDPOINT=etcd:2379`. `torchrun` reads those,
rendezvouses through the etcd Service (rendered by `charts/experiments/templates/etcd.yaml`),
assigns node ranks dynamically, and then re-exports `RANK` / `WORLD_SIZE` / `LOCAL_RANK` /
`MASTER_ADDR` / `MASTER_PORT` into each training process it spawns — which is where `ddp.py`
reads them (via the argless `init_process_group()` env:// rendezvous). The image needs no sshd,
no Open MPI, and no `OMPI_*`→`torch.distributed` environment shim — the whole SSH/mpirun
apparatus that an MPIJob-based approach requires simply does not apply here.

## Environment variables

`ddp.py` is configured entirely by env (all optional, with defaults):

| var | default | meaning |
|---|---|---|
| `OUTPUT_DIR` | `/shared/output` | run output dir (set per workload to `.../torchrun-<backend>` or `.../pytorchjob-<backend>` so runs don't clobber) |
| `DATA_DIR` | `/shared/mnist-data` | shared, run-independent MNIST download dir (rank 0 downloads once) |
| `SNAPSHOT_PATH` | `$OUTPUT_DIR/snapshot.pt` | checkpoint file (written by rank 0 only) |
| `TOTAL_EPOCHS` | `3` | epochs to train |
| `SAVE_EVERY` | `1` | snapshot every N epochs |
| `BATCH_SIZE` | `32` | per-device batch size |
| `USE_MLFLOW` | `0` | `1` enables mlflow logging (lazy import; degrades to no-tracking on any failure) |
| `TRACKING_URI` | `file://$HOME/mlruns` | mlflow tracking URI (only when `USE_MLFLOW=1`) |

## Build and push

Account and region are derived from your current credentials — nothing to hand-edit. Run from
the `infra/eks` directory:

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=$(aws configure get region || echo us-west-2)   # must match the EKS cluster's region
TAG=$(git rev-parse --short HEAD)
IMAGE=${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/ddp-sample:${TAG}

aws ecr describe-repositories --repository-names ddp-sample --region "$REGION" >/dev/null 2>&1 \
  || aws ecr create-repository --repository-name ddp-sample --region "$REGION" \
       --image-scanning-configuration scanOnPush=true

aws ecr get-login-password --region "$REGION" \
  | finch login --username AWS --password-stdin "${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"

# --platform linux/amd64 is required when building on Apple Silicon: EKS nodes are x86_64.
# This Dockerfile copies one script onto a prebuilt base with only a python-etcd pip layer, so
# the cross-build is just the base pull plus a small install + COPY — fast even under emulation.
finch build --platform linux/amd64 -t "$IMAGE" manifests/ddp-sample
finch push "$IMAGE"
```

Use plain `docker` instead of `finch` if you have it; the commands are otherwise identical. The
whole Basic02 flow (this build/push, then both workloads) is also wrapped in
[`scripts/run-basic02.sh`](../../scripts/run-basic02.sh), which auto-detects account/region/tag
and runs end to end. This manual path is for local Dockerfile iteration; wire it into your own
CI (build on push, push to ECR via OIDC) once the image stabilizes.

## Verified facts (so you don't have to re-derive them)

- The `torchrun`/PyTorchJob path needs no SSH or MPI: `spec.elasticPolicy` makes the operator
  inject the etcd rendezvous endpoint (`PET_RDZV_BACKEND=etcd` / `PET_RDZV_ENDPOINT=etcd:2379`),
  `torchrun` performs the rendezvous and re-exports `RANK`/`WORLD_SIZE`/`LOCAL_RANK`/
  `MASTER_ADDR`/`MASTER_PORT` into the training process, and `ddp.py` reads them directly via
  the argless `init_process_group()`. etcd runs as its own Deployment+Service in the namespace.
- The shared mount is written as root (uid 0). This image runs as root, and every shared
  backend hands root a writable mount — FSx OpenZFS exports `no_root_squash` (`openzfs.tf`),
  FSx Lustre mounts as root, and the EFS Access Point pins `posixUser` 0 (`efs.tf`) — so writes
  to `/shared` are owned correctly with no `chown` init container.

## Verification status

- **CPU (gloo), PyTorchJob, 2 Workers across 2 nodes** — verified on the distai-eks-blog EKS
  cluster (`cpu` NodePool) with this MNIST image: etcd rendezvous, `[rank 0/2]` / `[rank 1/2]`,
  `backend=gloo`, loss decreasing 0.20 → 0.06 across 3 epochs, job Succeeded, rank-0 save to the
  shared mount. The single-node torchrun path (2 procs, gloo) was verified in the same run.
- **GPU (nccl), PyTorchJob** — reviewed but NOT yet exercised on a GPU cluster. The manifest
  renders to valid YAML, but the NCCL path itself is unproven here.

## Known limitations / before you scale up

- **Single GPU per Worker assumed.** `ddp.py` maps `LOCAL_RANK` to `cuda:$LOCAL_RANK`, which is
  correct for one proc per GPU (`nprocPerNode == gpu.count`). Multiple GPUs per proc would need
  a device-assignment change plus a matching `nprocPerNode` / `gpu.count` bump (documented in
  the PyTorchJob manifest header).
- **Image is pinned by tag, not digest** (`pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime`).
  Fine for a sample; pin by digest for production.

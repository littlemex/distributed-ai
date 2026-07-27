# ddp-sample image

Minimal DistributedDataParallel image used by the `pytorchjobTrain` (multi-node PyTorchJob) and
`torchrunTrain` (single-node, zero-operator) workloads in `charts/experiments`. It trains an
MNIST MLP with `torch.nn.parallel.DistributedDataParallel` on top of
`pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime` — and nothing else: `torch` and `torchvision`
both ship in that base image, so there is not a single extra pip layer.

`ddp.py` is adapted from awsome-distributed-ai's `3.test_cases/pytorch/ddp/ddp.py`. The three
deliberate differences from that upstream sample are documented at the top of `ddp.py`:
c10d rendezvous instead of etcd, MNIST data + snapshot on the shared PVC mount (rank 0
downloads, the rest read), and a rank-0-only snapshot write. mlflow is optional (lazy import,
only when `USE_MLFLOW=1`), so it is not baked into the image.

## Why it is this small

The training runs under `torchrun`, either directly (single-node Job, `--standalone`) or under
a Kubeflow PyTorchJob. In the PyTorchJob case the Training Operator does not hand the container
`RANK` / `WORLD_SIZE` / `MASTER_ADDR` as plain pod env vars — a Worker-only job gets only the
torchrun-native `PET_*` variables, and the manifest's `spec.elasticPolicy` makes the operator
inject `PET_RDZV_BACKEND=c10d` plus `PET_RDZV_ENDPOINT=<job>-worker-0:23456`. `torchrun` reads
those, elects Worker-0 as the c10d rendezvous host, assigns node ranks dynamically, and then
re-exports `RANK` / `WORLD_SIZE` / `LOCAL_RANK` / `MASTER_ADDR` / `MASTER_PORT` into each
training process it spawns — which is where `ddp.py` reads them (via the argless
`init_process_group()` env:// rendezvous). Either way the image needs no sshd, no Open MPI, no
etcd, and no `OMPI_*`→`torch.distributed` environment shim — the whole SSH/mpirun apparatus that
an MPIJob-based approach requires simply does not apply here.

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

```bash
ACCOUNT_ID=<your-account-id>
REGION=<your-region>          # must match the EKS cluster's region
REPO=ddp-sample

aws ecr create-repository --region "$REGION" --repository-name "$REPO" \
  --image-scanning-configuration scanOnPush=true

aws ecr get-login-password --region "$REGION" \
  | finch login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# --platform linux/amd64 is required when building on Apple Silicon: EKS nodes are x86_64.
# This Dockerfile copies one script onto a prebuilt base with no pip layer, so the cross-build
# is just the base pull plus a COPY — fast even under finch's emulation.
cd manifests/ddp-sample
TAG=$(git rev-parse --short HEAD)
finch build --platform linux/amd64 -t "${REPO}:${TAG}" .
finch tag "${REPO}:${TAG}" "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO}:${TAG}"
finch push "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO}:${TAG}"
```

Use plain `docker` instead of `finch` if you have it; the commands are otherwise identical.
This manual path is for local Dockerfile iteration; wire it into your own CI (build on push,
push to ECR via OIDC) once the image stabilizes.

## Verified facts (so you don't have to re-derive them)

- The `torchrun`/PyTorchJob path needs no SSH, MPI, or etcd: `spec.elasticPolicy` makes the
  operator inject the c10d rendezvous endpoint (`PET_RDZV_BACKEND` / `PET_RDZV_ENDPOINT`),
  `torchrun` performs the rendezvous and re-exports `RANK`/`WORLD_SIZE`/`LOCAL_RANK`/
  `MASTER_ADDR`/`MASTER_PORT` into the training process, and `ddp.py` reads them directly via
  the argless `init_process_group()`.
- The shared mount is written as root (uid 0). This image runs as root, and every shared
  backend hands root a writable mount — FSx OpenZFS exports `no_root_squash` (`openzfs.tf`),
  FSx Lustre mounts as root, and the EFS Access Point pins `posixUser` 0 (`efs.tf`) — so writes
  to `/shared` are owned correctly with no `chown` init container.

## Verification status

- **CPU (gloo), PyTorchJob, 2 Workers across 2 nodes** — verified on a small EKS cluster
  (2x r5a.large `cpu` pool) with the earlier HF-Trainer script; the DDP mechanics
  exercised (c10d rendezvous electing Worker-0, `[rank 0/2]` / `[rank 1/2]`, `backend=gloo`,
  synchronized `grad_norm`, job Succeeded, rank-0 save to the shared mount, one `OnFailure`
  restart on a lagging peer) are identical for this MNIST script — the training body is the only
  thing that changed. Re-run this MNIST image to re-confirm end to end.
- **GPU (nccl), PyTorchJob** — reviewed but NOT yet exercised on a GPU cluster. The manifest
  renders to valid YAML, but the NCCL path itself is unproven here.

## Known limitations / before you scale up

- **Single GPU per Worker assumed.** `ddp.py` maps `LOCAL_RANK` to `cuda:$LOCAL_RANK`, which is
  correct for one proc per GPU (`nprocPerNode == gpu.count`). Multiple GPUs per proc would need
  a device-assignment change plus a matching `nprocPerNode` / `gpu.count` bump (documented in
  the PyTorchJob manifest header).
- **Image is pinned by tag, not digest** (`pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime`).
  Fine for a sample; pin by digest for production.

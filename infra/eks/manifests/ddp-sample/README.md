# ddp-sample image

Minimal DistributedDataParallel image used by the `torchrunTrain` (single-node, zero-operator)
and `trainjobTrain` (multi-node, Kubeflow Trainer v2 `TrainJob`) workloads in
`charts/experiments`. It trains an MNIST MLP with `torch.nn.parallel.DistributedDataParallel` on
top of `pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime` — and nothing else: `torch` and
`torchvision` both ship in that base image, so there is not a single pip layer. `python-etcd`
used to be installed here for a v1-era self-hosted etcd rendezvous store; Trainer v2 replaced
that with the `PET_*` mechanism described below, so it was dropped once nothing imported it —
verified: `ddp.py` imports only `os`, `torch`/`torchvision`, nothing etcd-related.

`ddp.py` is adapted from awsome-distributed-ai's `3.test_cases/pytorch/ddp/ddp.py`. The two
deliberate differences from that upstream sample are documented at the top of `ddp.py`: every
rank downloads MNIST independently rather than rank-0-only + barrier (safe because
`download=True` is idempotent, and it avoids a barrier that could outlast NCCL's init timeout),
and only rank 0 writes the snapshot (the upstream sample has no rank guard, which is fine when
each rank writes a local path but is a corruption risk on a shared mount). mlflow is optional
(lazy import, only when `USE_MLFLOW=1`), so it is not baked into the image either.

## Why it is this small

The training runs under `torchrun`, either directly (single-node Job, `--standalone`) or under
a Kubeflow Trainer v2 `TrainJob`. In the TrainJob case the Trainer's torch plugin does not
rewrite the container command — it only injects the torchrun-native `PET_*` env vars
(`PET_NNODES` / `PET_NPROC_PER_NODE` / `PET_NODE_RANK`, the JobSet completion index /
`PET_MASTER_ADDR`+`PET_MASTER_PORT`, node-0's headless DNS) and opens the trainer port.
`spec.trainer.command` must therefore invoke `torchrun` itself; `torchrun` reads those `PET_*`
values as CLI defaults, performs the c10d rendezvous, and re-exports `RANK` / `WORLD_SIZE` /
`LOCAL_RANK` / `MASTER_ADDR` / `MASTER_PORT` into each training process it spawns — which is
where `ddp.py` reads them, via the argless `init_process_group()` env:// rendezvous. There is no
self-hosted rendezvous store (no etcd Service, no etcd Deployment): node-0 itself is the
rendezvous point. The image needs no sshd, no Open MPI, and no `OMPI_*`→`torch.distributed`
environment shim — the whole SSH/mpirun apparatus that an MPI-based launcher would require
simply does not apply here.

## Environment variables

`ddp.py` is configured entirely by env (all optional, with defaults):

| var | default | meaning |
|---|---|---|
| `OUTPUT_DIR` | `/shared/output` | run output dir (set per workload to `.../torchrun-<backend>` or `.../trainjob-<backend>` so runs don't clobber) |
| `DATA_DIR` | `/shared/mnist-data` | shared, run-independent MNIST download dir (every rank downloads; see above) |
| `SNAPSHOT_PATH` | `$OUTPUT_DIR/snapshot.pt` | checkpoint file (written by rank 0 only) |
| `TOTAL_EPOCHS` | `3` | epochs to train |
| `SAVE_EVERY` | `1` | snapshot every N epochs |
| `BATCH_SIZE` | `32` | per-device batch size |
| `USE_MLFLOW` | `0` | `1` enables mlflow logging (lazy import; degrades to no-tracking on any failure) |
| `TRACKING_URI` | `file://$HOME/mlruns` | mlflow tracking URI (only when `USE_MLFLOW=1`) |

## Build and push

The reference path for this image is the in-cluster BuildKit Job in `charts/experiments`
(Basic02 in the book walks through it) — it needs no local Docker/finch and no manual ECR login,
since Pod Identity handles the ECR auth and the image never leaves the cluster's network:

```bash
cd infra/eks
ECR_URL=$(terraform output -raw ddp_sample_ecr_url)

helm template exp charts/experiments -n "$NAMESPACE" \
    --set imageBuild.enabled=true \
    --set imageBuild.repository="$ECR_URL" \
    --set imageBuild.tag=v1 \
    -s templates/image-build-ddp-sample.yaml \
    | kubectl apply -f -

kubectl -n image-builder wait --for=condition=complete job/build-ddp-sample-v1 --timeout=30m
```

For local Dockerfile iteration only, `finch`/`docker` still work (cross-build with
`--platform linux/amd64` on Apple Silicon, since EKS nodes are x86_64):

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=$(aws configure get region || echo us-west-2)   # must match the EKS cluster's region
ECR_URL=$(terraform output -raw ddp_sample_ecr_url)     # <cluster_name>-ddp-sample, not "ddp-sample"
IMAGE="${ECR_URL}:local"

aws ecr get-login-password --region "$REGION" \
  | finch login --username AWS --password-stdin "${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"

finch build --platform linux/amd64 -t "$IMAGE" manifests/ddp-sample
finch push "$IMAGE"
```

Wire this into your own CI (build on push, push to ECR via OIDC) once the image stabilizes.

## Verified facts (so you don't have to re-derive them)

- The `torchrun`/TrainJob path needs no SSH or MPI: the Trainer torch plugin injects `PET_*`
  (see above), `torchrun` performs the rendezvous and re-exports `RANK`/`WORLD_SIZE`/
  `LOCAL_RANK`/`MASTER_ADDR`/`MASTER_PORT` into the training process, and `ddp.py` reads them
  directly via the argless `init_process_group()`. No etcd Service or Deployment exists in the
  namespace for this — node-0 is the rendezvous point.
- The shared mount is written as root (uid 0). This image runs as root, and every shared
  backend hands root a writable mount — FSx OpenZFS exports `no_root_squash` (`openzfs.tf`),
  FSx Lustre mounts as root, and the EFS Access Point pins `posixUser` 0 (`efs.tf`) — so writes
  to `/shared` are owned correctly with no `chown` init container.

## Verification status

- **CPU (gloo), TrainJob, 2 nodes** — verified on the distai-eks-blog EKS cluster (`cpu`
  NodePool) with this MNIST image: c10d rendezvous via node-0, loss decreasing across 3 epochs,
  job Succeeded, rank-0 save to the shared mount. The single-node torchrun path (2 procs, gloo)
  was verified in the same run.
- **GPU (nccl), TrainJob** — reviewed but NOT yet exercised end-to-end on a GPU cluster with
  this exact image; the manifest renders to valid YAML. (A separate torch.distributed all_reduce
  benchmark image, not this one, has been verified over NCCL/EFA on 2x p4d.24xlarge — see the
  book's EFA chapter — but that does not stand in for exercising `ddp.py` itself on GPU.)

## Known limitations / before you scale up

- **Single GPU per rank assumed.** `ddp.py` maps `LOCAL_RANK` to `cuda:$LOCAL_RANK`, which is
  correct for one proc per GPU (`trainjobTrain.nprocPerNode == gpu.count`). Multiple GPUs per
  proc would need a device-assignment change plus a matching `nprocPerNode` / `gpu.count` bump.
- **Image is pinned by tag, not digest** (`pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime`).
  Fine for a sample; pin by digest for production.

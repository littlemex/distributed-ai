# ddp-sample image

Minimal DistributedDataParallel image used by the `trainjobTrain` (multi-node Kubeflow Trainer v2
TrainJob) and `torchrunTrain` (single-node, zero-operator) workloads in `charts/experiments`. It
trains an MNIST MLP with `torch.nn.parallel.DistributedDataParallel` on top of
`pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime` — and nothing else: `torch` and `torchvision`
both ship in that base image.

`ddp.py` is adapted from awsome-distributed-ai's `3.test_cases/pytorch/ddp/ddp.py`. The two
deliberate differences from that upstream sample are documented at the top of `ddp.py`: MNIST
data + snapshot on the shared PVC mount, and a rank-0-only snapshot write. mlflow is optional
(lazy import, only when `USE_MLFLOW=1`), so it is not baked into the image.

## Why it is this small

The training runs under `torchrun`, either directly (single-node Job, `--standalone`) or under a
Kubeflow Trainer v2 TrainJob. In the TrainJob case the Trainer's torch plugin injects the
torchrun-native `PET_*` variables (`PET_NNODES` / `PET_NPROC_PER_NODE` / `PET_NODE_RANK` /
`PET_MASTER_ADDR` / `PET_MASTER_PORT`) and points torchrun at node-0 for the **c10d** rendezvous
— there is no self-hosted etcd Service, and therefore no etcd client dependency. `PET_NODE_RANK`
is fixed by the pod index, so `<job>-node-0-0` is always rank 0. `torchrun` then re-exports
`RANK` / `WORLD_SIZE` / `LOCAL_RANK` / `MASTER_ADDR` / `MASTER_PORT` into each training process it
spawns — which is where `ddp.py` reads them, via the argless `init_process_group()` env://
rendezvous. Note that the rendezvous backend (c10d) is orthogonal to the communication backend
(gloo on CPU, nccl on GPU).

The image needs no sshd, no Open MPI, and no `OMPI_*`→`torch.distributed` environment shim — the
whole SSH/mpirun apparatus that an MPIJob-based approach requires simply does not apply here.
(The NCCL/EFA benchmarks in `charts/experiments` do use sshd, but those run a different image.)

## Environment variables

`ddp.py` is configured entirely by env (all optional, with defaults):

| var | default | meaning |
|---|---|---|
| `OUTPUT_DIR` | `/shared/output` | run output dir. The workloads set it per job so runs don't clobber: `/shared/output/torchrun-<backend>` (torchrunTrain) and `/shared/output/trainjob` (trainjobTrain) |
| `DATA_DIR` | `/shared/mnist-data` | shared, run-independent MNIST download dir (every rank calls `download=True`; it is idempotent) |
| `SNAPSHOT_PATH` | `$OUTPUT_DIR/snapshot.pt` | checkpoint file (written by rank 0 only) |
| `TOTAL_EPOCHS` | `3` | epochs to train |
| `SAVE_EVERY` | `1` | snapshot every N epochs |
| `BATCH_SIZE` | `32` | per-device batch size |
| `USE_MLFLOW` | `0` | `1` enables mlflow logging (lazy import; degrades to no-tracking on any failure) |
| `TRACKING_URI` | `file://$HOME/mlruns` | mlflow tracking URI (only when `USE_MLFLOW=1`) |

## Build and push

The supported path is the **in-cluster** build: no local docker/finch, and no cross-build for the
x86_64 nodes. Render the BuildKit Job from the catalog and let the cluster build and push it. The
ECR repository is created by Terraform (`image_builder_enabled`, default on), so read its URL from
the output rather than reconstructing it:

```bash
# from infra/eks
ECR_URL=$(terraform output -raw ddp_sample_ecr_url)

helm template exp charts/experiments -n "$NAMESPACE" \
  --set imageBuild.enabled=true \
  --set imageBuild.repository="$ECR_URL" \
  --set imageBuild.tag=v1 \
  -s templates/image-build-ddp-sample.yaml \
  | kubectl apply -f -

kubectl -n image-builder wait --for=condition=complete job/build-ddp-sample-v1 --timeout=30m
```

Re-running the same tag needs an explicit `kubectl -n image-builder delete job build-ddp-sample-v1`
first (a Job's pod template is immutable, so `kubectl apply` on a completed Job is a silent no-op).
Bumping the tag instead is the easier habit and avoids the `:latest`/kubelet-cache trap.

The BuildKit Job fetches this directory straight from the repo via BuildKit's git context, so no
`git clone` is needed either. For local Dockerfile iteration you can of course still build with
docker/finch and push by hand — use `--platform linux/amd64` if you are on Apple Silicon, since
the nodes are x86_64.

## Verified facts (so you don't have to re-derive them)

- The TrainJob path needs no SSH or MPI: the Trainer torch plugin injects `PET_*`, `torchrun`
  performs the c10d rendezvous against node-0 and re-exports `RANK`/`WORLD_SIZE`/`LOCAL_RANK`/
  `MASTER_ADDR`/`MASTER_PORT` into the training process, and `ddp.py` reads them directly via the
  argless `init_process_group()`. Nothing extra runs in the namespace for rendezvous.
- Every rank downloads MNIST (`download=True` is idempotent) rather than rank 0 downloading behind
  a barrier: a rank-0-only fetch plus a barrier deadlocks if the download outlasts the collective
  init timeout, and when `DATA_DIR` is node-local every rank needs its own copy anyway. Only the
  snapshot write is rank-0-only.
- The shared mount is written as root (uid 0). This image runs as root, and every shared backend
  hands root a writable mount — FSx OpenZFS exports `no_root_squash` (`openzfs.tf`), FSx Lustre
  mounts as root, and the EFS Access Point pins `posixUser` 0 (`efs.tf`) — so writes to `/shared`
  are owned correctly with no `chown` init container.

## Verification status

- **CPU (gloo), 2 nodes** — verified on the distai-eks-blog EKS cluster (`cpu` NodePool) with this
  MNIST image: `[rank 0/2]` / `[rank 1/2]`, `backend=gloo`, loss decreasing across 3 epochs, job
  Succeeded, rank-0 save to the shared mount. The single-node torchrun path (2 procs, gloo) was
  verified in the same run.
- **GPU (nccl)** — exercised via the TrainJob on a g5/g6 pool: `backend=nccl cuda_available=True`,
  resuming from a CPU-written snapshot and completing. Larger multi-node NCCL runs are covered by
  the dedicated EFA benchmarks, not by this image.

## Known limitations / before you scale up

- **Single GPU per Worker assumed.** `ddp.py` maps `LOCAL_RANK` to `cuda:$LOCAL_RANK`, which is
  correct for one proc per GPU (`nprocPerNode == gpu.count`). Multiple GPUs per proc would need a
  device-assignment change plus a matching `nprocPerNode` / `gpu.count` bump.
- **Image is pinned by tag, not digest** (`pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime`).
  Fine for a sample; pin by digest for production.

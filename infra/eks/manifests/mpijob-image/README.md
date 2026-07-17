# mpijob-hf-sample image

Custom image used by `gpu-distributed-mpijob-train.yaml.tpl` (and, for consistency, its
zero-operator sibling `cpu-gpu-torchrun-train.yaml.tpl`). Layers Open MPI + openssh-server +
the mpi-operator SSH config on top of `pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime`, plus
`transformers`/`datasets`/`accelerate`.

## Why this exists

`pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime` ships neither Open MPI nor sshd, and the
Launcher's `mpirun` rsh's into each Worker over SSH — neither has anything to run on a stock
image. `sshd_config` and the `ssh_config`/`sshd_config` edits in the `Dockerfile` are copied
from `github.com/kubeflow/mpi-operator`'s own `build/base/Dockerfile` and
`build/base/sshd_config` — the same base every upstream `examples/v2beta1/*` sample builds on
— not reinvented. Open MPI itself is not part of that upstream base image (it comes from the
example image built on top of it); it is added here explicitly.

The consuming manifest's Worker sets `command`/`args` explicitly
(`[/usr/sbin/sshd]` / `[-De, -f, /home/mpiuser/.sshd_config]`) rather than relying on
mpi-operator's auto-injection. This matters: when both are left unset, mpi-operator v0.6.0
injects only `/usr/sbin/sshd -De` — no `-f` — so sshd falls back to the stock
`/etc/ssh/sshd_config`, which points at `/etc/ssh/ssh_host_*_key` files this image never
generates (no `ssh-keygen -A`), and exits with `no hostkeys available`. Confirmed by reading
`pkg/controller/mpi_job_controller.go`'s `newWorker()` in mpi-operator v0.6.0 and reproducing
the exact failure on a real cluster.

## Build and push

```bash
ACCOUNT_ID=<your-account-id>
REGION=<your-region>          # must match the EKS cluster's region
REPO=mpijob-hf-sample

aws ecr create-repository --region "$REGION" --repository-name "$REPO" \
  --image-scanning-configuration scanOnPush=true

aws ecr get-login-password --region "$REGION" \
  | finch login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# --platform linux/amd64 is required when building on Apple Silicon: EKS nodes are x86_64,
# and this Dockerfile is pure apt/pip (prebuilt wheels, no compilation), so cross-building
# under finch's emulation is slow but reliable — expect several minutes.
cd manifests/mpijob-image
finch build --platform linux/amd64 -t "${REPO}:v1" .
finch tag "${REPO}:v1" "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO}:v1"
finch push "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO}:v1"
```

Use plain `docker` instead of `finch` if you have it; the commands are otherwise identical.

## Verified facts (so you don't have to re-derive them)

- Base image has neither `mpirun` nor `sshd`: `finch run --rm pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime which mpirun sshd` returns nothing for both.
- Non-interactive SSH does **not** inherit the image's Docker `ENV PATH`. `ssh -p 2222 host 'echo $PATH'` shows only `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games` — missing `/opt/conda/bin`, where this image's Python lives. This is why the MPIJob manifest's Launcher invokes `/opt/conda/bin/python3` by absolute path rather than a bare `python3`.
- sshd runs fine as the non-root `mpiuser` (uid 1000) with `HostKey /home/mpiuser/.ssh/id_rsa` pointed at the operator-mounted Secret — no baked host key needed. Verified with a self-contained single-container SSH + `mpirun -np 2 -H localhost:2` rehearsal before deploying to the cluster.
- The EFS access point used for shared storage (`efs.tf`) is owned by uid/gid 0; this image's `mpiuser` is uid 1000. The consuming manifests run a root `initContainer` (`securityContext: {runAsUser: 0}`) to `chown` the mount once before the main containers start as `mpiuser`.

## Verification status

- **CPU (gloo), MPIJob, 2 workers across 2 nodes** — verified end-to-end on a real cluster:
  MPIJob reached `Succeeded`, all training steps completed, loss decreased monotonically, and
  only rank 0 wrote the final checkpoint to EFS. The single-node `torchrun` sibling was also
  run to completion on a GPU node.
- **GPU (nccl), MPIJob** — reviewed but NOT yet exercised on a GPU cluster. The manifest renders
  to valid YAML and the Launcher is pinned to a CPU node so it never provisions a spare GPU node,
  but the NCCL path itself is unproven here.

## Known limitations / before you scale up

These are deliberately NOT patched into the shipped `v1` image, so that the image described by
this Dockerfile is exactly the one verified above. Address them when moving past the toy
SmolLM2-135M / one-GPU-per-worker setup:

- **No end-of-training barrier in `train_smollm.py`.** Only rank 0 calls `save_model`; the other
  ranks fall out of `main()` and exit, and there is no `dist.barrier()` before the save nor a
  `destroy_process_group()` after. Harmless for a 135M model with a fast EFS write, but a larger
  model (slow rank-0 save) can let the other ranks tear down the process group first and trip a
  NCCL/gloo watchdog timeout on rank 0. Add a barrier around the save and a `destroy_process_group()`
  at the end before using this for anything real.
- **Single GPU per worker assumed.** `train_smollm.py` does not map `LOCAL_RANK` to a CUDA device,
  so multi-GPU-per-node needs a `CUDA_VISIBLE_DEVICES`/device-assignment change plus the coupled
  `-np` / `slotsPerWorker` / `nvidia.com/gpu` bump documented in the MPIJob manifest header.
- **`setcap CAP_NET_BIND_SERVICE` in the Dockerfile is a no-op at the default port.** sshd listens
  on 2222 (a non-privileged port), so `mpiuser` needs no capability to bind it; the setcap/remove
  dance only matters if you drop `SSH_PORT` below 1024.
- **Image is pinned by tag, not digest** (`pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime`), and
  `sshd_config` relies on the base image's default `PasswordAuthentication` rather than setting it
  explicitly. Both are fine for a sample; tighten for production.

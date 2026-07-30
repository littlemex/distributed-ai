# experiments chart

Hand-run experiment workloads for the distributed-ai EKS reference cluster. This is a
**local Helm chart used only via `helm template | kubectl apply`** — do not `helm install`
it. There is no Release to manage; each workload is a self-contained set of objects you
render, apply, watch, and delete yourself.

This chart replaces the earlier `manifests/*.yaml.tpl` sed-substitution templates (see the
top of `Chart.yaml` for why: sed produced invalid-until-substituted YAML with no schema
check, and could not express GPU-vs-CPU conditional resource blocks cleanly).

## Quickstart

```bash
kubectl create ns my-experiment
helm template exp . -n my-experiment --set neuronDdp.enabled=true --set neuronDdp.nodeRole=trn2 \
  | kubectl apply -f -
```

Always pass the namespace with `-n` (the standard Helm flag) or `--set namespace=...` —
**not both differently** (see Known Issues). `-n` is the recommended form; it also matches
your subsequent `kubectl -n my-experiment ...` commands.

## Workload catalog

| values key | enables | verified on | status |
|---|---|---|---|
| `neuronProbe` | single-node Neuron sanity check (`neuron-probe` pod) | trn2.48xlarge | verified |
| `neuronDdp` | two-node Neuron DDP over EFA (ConfigMap + `neuron-server`/`neuron-client` pods) | trn2.48xlarge x2 | **verified**: world_size=64 all-reduce + aws-neuron-samples MNIST MLP, both completed; EFA confirmed via libfabric log + host RDMA-write counters |
| `ncclProbe` | single-node NVIDIA/EFA sanity check (`nccl-probe` pod) | — | untested on this module (defaults carried over from a B300 reference; this module's own verified GPU run was g5.24xlarge/A10G, no EFA) |
| `ncclSshd` | two-node NVIDIA NCCL bench over EFA (`nccl-server`/`nccl-client` pods) | — | untested on this module, same caveat as `ncclProbe` |
| `torchrunTrain` | single-node MNIST MLP DDP via `torchrun` (batch/v1 Job, zero operator) | c6a.large (CPU/gloo, single-node) / g5.24xlarge (GPU path reviewed, not yet run) | gloo verified via the two-node gloo probe below; nccl path untested |
| `trainjobTrain` | two-node MNIST MLP DDP via Kubeflow Trainer v2 TrainJob (`trainer.kubeflow.org/v1alpha1`), on the cluster runtime `torch-distributed-eks` | r5a.large x2 (CPU/gloo) | migrated from the verified `pytorchjobTrain` (PyTorchJob) — identical DDP mechanics (`[rank 0/2]`+`[rank 1/2]` gloo, synchronized grads, checkpoint to the shared mount by rank 0); the TrainJob wrapper itself not yet re-run on a live cluster; nccl path reviewed, not yet run on a GPU cluster |
| `gpuServingVllm` | single-GPU vLLM OpenAI-compatible serving | g5.24xlarge (A10G x4) node bring-up verified (`nvidia-smi` confirmed the GPU); vLLM serving itself not yet exercised through this chart | partially verified |
| `neuronServingVllm` | Neuron vLLM serving (whole trn2 node) | — | untested (no `neuron-cache-pvc` provisioned during review) |
| `vllmRay` | two-node pipeline-parallel vLLM via Ray | — | untested |

A **two-node CPU gloo all-reduce** (`ALL 10 STEPS OK. world_size=2`, `DONE - SUCCESS`) was
verified on two separate `cpu` pool nodes using a hand-written probe outside this chart's
`torchrunTrain`/`trainjobTrain` templates; the underlying `cpu` NodePool + gloo collective
path itself is confirmed working.

"Verified" always means a specific instance type + image tag + value set, not "this
workload's current defaults." Where the defaults differ from what was verified, that is
called out per-workload in `values.yaml`.

## Prerequisite resources — check before you `helm template | apply`

Every workload's failure mode for a missing prerequisite is the same: the Pod/Job stays
**Pending** and the event log is the only way to tell why. Check this table first.

| workload | prerequisite | how to check | symptom if missing |
|---|---|---|---|
| `torchrunTrain`, `trainjobTrain` | the `sharedStorage.backend` static PV bound and free — default `openzfs` → `openzfs-shared` (`openzfs_enabled=true`, ON by default); or `fsx` → `fsx-training`, `efs` → `efs-neuron-workspace` | `kubectl get pv $(helm template exp . --set ...\|grep volumeName)` — or just `kubectl get pv openzfs-shared` for the default | PVC `shared-claim` stays Pending |
| `torchrunTrain`, `trainjobTrain` | `trainjobTrain.image` / `torchrunTrain.image` set to a real image (PyTorch + `ddp.py` MNIST MLP; see `manifests/ddp-sample/` in the module root for the build) | — | render itself fails with a `required` error (not a Pending — this one fails loud) |
| `neuronServingVllm` | PVC `neuron-cache-pvc` (RWX; not created by this chart — bind it to your own EFS/FSx StorageClass or a static PV before enabling) | `kubectl get pvc neuron-cache-pvc` | Deployment's Pod stays Pending |
| `gpuServingVllm`, `neuronServingVllm` | (optional) Secret `hf-token` with key `token`, for gated HF models | `kubectl get secret hf-token` | fine if ungated model; gated model pull fails at container start |
| any GPU workload | a `device_plugin="nvidia"` accelerator pool exists in `accelerator_pools` (terraform.tfvars) | `kubectl get nodepool` | Pod stays Pending, no matching node-role |
| any Neuron workload | a `device_plugin="neuron"` accelerator pool exists | `kubectl get nodepool` | Pod stays Pending |
| `trainjobTrain` | Kubeflow Trainer v2 control plane (installed by `trainer.tf`, `trainer_enabled=true`) | `kubectl get pods -n kubeflow-system` | TrainJob created but never schedules Pods |

### Toleration ↔ NodePool taint mismatch

`ncclProbe`/`ncclSshd` tolerate 5 taints (`nvidia.com/gpu`, `vpc.amazonaws.com/efa`,
`workload=bench`, `capacity-reservation`, `sagemaker.amazonaws.com/node-health-status`) —
carried over from a different cluster's B300 NodePool. If **your** `gpu-*` pool
(`karpenter-resources.tf`) does not set a matching `workload=bench` or SageMaker taint,
those tolerations are simply unused (harmless). If your pool sets a taint NOT in this list,
the Pod stays Pending. Check your pool's actual taints against the toleration list before
assuming the copy-paste example works verbatim.

## Re-running a workload (delete before re-apply)

Pod and Job specs are largely **immutable** after creation. Re-rendering with different
`--set` values and re-applying fails with `field is immutable`/`may not change fields
other than...` for `neuronProbe`, `neuronDdp`, `ncclProbe`, `ncclSshd`, `torchrunTrain`
(Job), and `trainjobTrain` (TrainJob) alike. Always delete the previous render before
applying a changed one:

```bash
helm template exp . -n my-experiment --set neuronDdp.enabled=true | kubectl delete -f - --ignore-not-found
helm template exp . -n my-experiment --set neuronDdp.enabled=true --set neuronDdp.disableZerocopy=true \
  | kubectl apply -f -
```

## Teardown and the static-PV trap

`torchrunTrain`/`trainjobTrain`'s PVC (`shared-claim`) binds the single static PV of the
selected `sharedStorage.backend` (default `openzfs-shared`; or `fsx-training` / `efs-neuron-
workspace`), which **can only be Bound to one PVC at a time**. If you delete the PVC (e.g. via
`kubectl delete -f -` above) while its reclaim policy is `Retain`, the PV goes to `Released`
and the *next* apply (same namespace or a different one) binds nothing — PVC Pending forever,
no useful event. Recover by clearing the stale claimRef on whichever PV you use, e.g. for the
default:

```bash
kubectl patch pv openzfs-shared --type json -p '[{"op":"remove","path":"/spec/claimRef"}]'
```

Bare pods (`neuronProbe`, `neuronDdp`, `ncclProbe`, `ncclSshd`) are not requeued on node
loss (Capacity Block expiry, Spot interruption, hardware fault) — the Pod is simply gone.
Re-apply from scratch, including re-distributing SSH keys (they live in-container, not in a
Secret).

## Known issues

- **Neuron `nrt_init` fails with `ucode_lib_ll_create failed, error: 6`.** Cause: the host
  kernel driver (`aws-neuronx-dkms`) and the in-container Neuron runtime disagree on the
  `zerocopy` ioctl struct size (an ABI mismatch — the driver returns `EINVAL`). Seen with
  host dkms 2.29.0.0 + container runtime 2.32.31.0 (this chart's default `neuronDdp.image`
  tag, sdk2.30.0 DLC). **Not a hugepages problem.** Permanent fix: align the node AMI's
  `aws-neuronx-dkms` with the DLC's Neuron SDK release. Workaround:
  `--set neuronDdp.disableZerocopy=true` (off by default so it doesn't silently mask the
  version skew — see the flag's comment in `values.yaml`).
- **Shared-mount writes run as root.** `torchrunTrain`/`trainjobTrain` write the MNIST data
  and snapshot to the `sharedStorage.backend` mount, and the `ddp-sample` image runs as root
  (uid 0). Every backend hands root a writable mount with no init-container `chown`:
  FSx OpenZFS exports `no_root_squash` (`openzfs.tf`), FSx Lustre mounts as root, and the EFS
  Access Point pins `posixUser` uid/gid 0 (`efs.tf`). If you fork this and run the training
  container as a non-root uid, this changes per backend — the EFS Access Point would squash
  writes to uid 0 (`Operation not permitted` unless you reconfigure its `posixUser`), while
  the FSx backends honour the container uid. Keeping the container as root is the simplest
  path across all three.
- **Closed/NAT-less networks**: the sshd containers (`neuronDdp`, `ncclSshd`) run
  `apt-get install openssh-server` at startup if the image doesn't already ship it. With no
  egress this fails, and `command -v sshd` then aborts the container with a clear error —
  but only after the apt-get timeout. Bake `openssh-server` into your own image if you run
  in an egress-restricted subnet.
- **Karpenter + hugepages**: Karpenter does not size a new node against a `hugepages-2Mi`
  request when deciding what instance to launch. Requesting hugepages on a Pod that
  *triggers provisioning* (i.e., no matching node exists yet) makes Karpenter report "no
  instance type has enough resources" and it never creates the NodeClaim — even though the
  chosen instance type has plenty of hugepages once booted. `neuronProbe` and `ncclProbe`
  deliberately request none for this reason; `neuronDdp`/`ncclSshd` request hugepages
  because they're normally applied against an already-warm node.
- **`namespace` must not have a non-empty literal default.** See `values.yaml`'s comment on
  the `namespace` key — this bit us during review (a `namespace: default` value silently
  overrode `-n <ns>` on every render) and is now fixed, but if you fork this chart and add a
  default namespace value here, you will reproduce the same bug.
- **`trainjobTrain`'s `command` must start with `torchrun`.** For plain torch the Trainer v2
  plugin does NOT rewrite the command — it only injects the `PET_*` env
  (`PET_NNODES`/`PET_NPROC_PER_NODE`/`PET_NODE_RANK`/`PET_MASTER_ADDR`/`PET_MASTER_PORT`) and
  opens the trainer port. `torchrun` reads those as CLI defaults, which is why the template
  omits `--nnodes`/`--nproc-per-node`/`--master-addr`. Writing `command: [python, ...]` instead
  bypasses `torchrun`, the `PET_*` go unread, and every pod runs as `world_size=1` — a job that
  "succeeds" without ever training distributed. `PET_MASTER_ADDR` resolves to the JobSet
  headless DNS `<job>-node-0-0.<job>`, so node-0 is the rendezvous store (the self-hosted etcd
  the v1 chart used is gone).
- **`trainjobTrain.nprocPerNode` is set explicitly, never `auto`.** Left unset on a CPU node the
  plugin derives it from the CPU request (`getNumCPUPerNode`), so a large request would spawn
  dozens of procs. One proc per node (CPU) or one per GPU (nccl) is the intent, so it is pinned.
- **The cluster runtime `torch-distributed-eks` is where the pod scaffolding lives.** The
  `replicatedJob` and container are both named `node` (the plugin keys `PET_*` injection off the
  `node` container — renaming silently drops it to `world_size=1`), and it carries NO
  `trainer.kubeflow.org/managed-by=runtimes-installer` label (that label would make the chart's
  runtimes-installer hook delete this runtime on the next `helm upgrade`).

## Security notes (read before copying into a shared/multi-tenant cluster)

- `neuronDdp`/`ncclSshd`/`ncclProbe` use `hostNetwork: true` for EFA/RDMA — this puts the
  container in the node's network namespace, which can reach the node's IMDS and thus its
  IAM role. Treat anyone who can `kubectl exec` into these Pods as having that role's
  permissions.
- `ncclProbe`/`ncclSshd` run `privileged: true` for `/dev/gdrdrv` (GPUDirect) access. EFA
  itself does **not** require `privileged` — `neuronDdp` in this same chart proves
  `IPC_LOCK` alone is sufficient for EFA/RDMA. If you don't need gdrcopy, this is more
  privilege than the workload needs; it's left as-is here because the reduced-privilege path
  is unverified without a GPU+EFA node to test on (see the workload catalog above).
- sshd on port 2222 is reachable from anywhere the Pod's VPC/subnet routes, gated only by
  key-based auth. Fine for a short-lived experiment namespace; restrict via Security Group
  or keep the namespace's lifetime short if that's a concern.

## Layout

```
Chart.yaml, values.yaml       chart metadata + all workload parameters (see inline comments)
templates/_helpers.tpl        shared helpers: experiments.namespace, sharedVolumeName, tolerations, sshd command, neuron env
templates/shared-pvc.yaml     single shared-claim PVC (backend openzfs|fsx|efs), shared by torchrunTrain + trainjobTrain
templates/<workload>.yaml     one file per workload; header comment has render/verify/troubleshooting steps
files/allreduce_test.py       torch-neuronx all-reduce probe, mounted into neuronDdp via ConfigMap
```

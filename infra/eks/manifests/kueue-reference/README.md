# kueue-reference — queue one existing NodePool, opt one namespace in

Reference ClusterQueue/ResourceFlavor/LocalQueue for Kueue (the controller `infra/eks/kueue.tf` always installs). Not applied by Terraform: which NodePool to queue, how much of it to allow, and which namespace may use it are workload-shape-specific, exactly like `accelerator_pools` in `accelerator-pools.auto.tfvars`.

## What this gives you

Submitting more TrainJobs/RayJobs than the quota allows no longer means Karpenter tries to launch nodes for all of them at once (and fails some with `InsufficientInstanceCapacity`, or launches more nodes than you meant to pay for). Instead, Kueue holds the excess as pending Workloads and admits them as earlier ones finish — the same NodePool, the same accelerator_pools definition, just with an admission gate in front of it.

## What this does NOT give you

- **No capacity reservation.** The quota you set is a ceiling on what Kueue will *try* to admit, not a guarantee the NodePool can supply it. A quota the instance types/AZ/Spot pool cannot back looks exactly like an ordinary unschedulable-pod wait.
- **No cross-NodePool sharing.** This example is one ClusterQueue over one NodePool. Kueue's [cohort](https://kueue.sigs.k8s.io/docs/concepts/cohort/) mechanism can share quota across several ClusterQueues; not covered here.
- **No per-namespace isolation on the same NodePool.** The ResourceFlavor/ClusterQueue this template creates are named only from `__NODEPOOL_NAME__`, not from the namespace, because they are genuinely cluster-scoped objects — Kueue has no namespaced ClusterQueue. Re-running Usage for a second namespace against the same `__NODEPOOL_NAME__` overwrites the first namespace's quota, and the first `LocalQueue` in each namespace keeps pointing at the one shared `ClusterQueue`/`ResourceFlavor`. Deleting those two objects (Removing it, below) removes the queue for every namespace sharing them, not just yours. Two namespaces that both want to queue the same NodePool, with independent quotas, need Kueue's cohort mechanism (not covered here), not two copies of this template.
- **No deadline/time-of-day awareness.** Kueue admits by quota and priority, not by how long a job is expected to run or when its window of opportunity closes.

## Usage

```bash
export NS=distai POOL=gpu-ddp GPU_QUOTA=2
kubectl label namespace "$NS" managed-by-kueue=true --overwrite
cd infra/eks/manifests/kueue-reference
sed -e "s/__NAMESPACE__/$NS/g" \
    -e "s/__NODEPOOL_NAME__/$POOL/g" \
    -e "s/__GPU_QUOTA__/$GPU_QUOTA/g" \
    queue.yaml.tmpl | kubectl apply -f -
```

`GPU_QUOTA` has to cover a whole Workload, not one Pod: a TrainJob with `numNodes: 2` and one GPU per node needs a quota of at least 2, not 1, to ever be admitted — size it as (GPUs per node) × (nodes in the job) × (how many such jobs you want to run at once), against what the target NodePool's instance types and AZ/Spot pool can actually supply. See the comment in `queue.yaml.tmpl` for the CPU/memory quotas, which gate admission the same way the GPU one does and are not covered by getting `GPU_QUOTA` right alone.

## Opting a namespace in

`kueue.tf` scopes Kueue's webhooks to namespaces labelled `managed-by-kueue: "true"` (Kueue's own documented ["opt-in namespace management"](https://kueue.sigs.k8s.io/docs/tasks/manage/enforce_job_management/opt_in_namespace_management/) pattern, not this repo's invention) — a namespace without that label is completely outside Kueue's webhooks, which matters on a cluster shared with workloads this repo does not own. The Usage block above applies the label with a plain `kubectl label namespace`, as its own step, deliberately not bundled into `queue.yaml.tmpl` as a `Namespace` manifest: this template's natural inverse is `kubectl delete -f` on its own rendered output, and a `Namespace` object in that path would delete the whole namespace — including things this template never created, like a shared PVC applied in an earlier workshop step. Labelling an already-labelled namespace again is harmless.

## Using the queue

Set the queue-name label **at creation time**, in the object's `metadata.labels`. `charts/experiments`'s `trainjobTrain.queueName` Helm value does this for you (see that chart's README's prerequisites table, the `trainjobTrain.queueName` row). A TrainJob created *without* this label, in a namespace that does not carry `managed-by-kueue=true`, runs immediately and unqueued — not held, not Pending, the opposite of what setting `queueName` is for. There is no supported way to bring an already-created, already-running TrainJob under a queue after the fact: Kueue decides whether to hold a job's Pods at creation, through the same webhook that reads this label, so a label added afterward has nothing left to hold.

## Removing it

```bash
kubectl delete -n "$NS" localqueue "$POOL"
kubectl delete clusterqueue "${POOL}-cq"
kubectl delete resourceflavor "$POOL"
```

A ClusterQueue that still has admitted Workloads is not rejected outright: `kubectl delete` is accepted and the object stays `Terminating`, held by Kueue's own finalizer, until every admitted Workload referencing it finishes or is deleted first. If another namespace's LocalQueue also points at this `ClusterQueue`/`ResourceFlavor` (see "What this does NOT give you" above), deleting them removes the queue for that namespace too. Uninstalling `kueue.tf`'s Helm release entirely removes Kueue's CRDs along with it (see that file's header comment) and takes every ClusterQueue/LocalQueue/ResourceFlavor/Workload with it, which can itself hang on the same finalizer with no controller left to clear it — do the per-queue cleanup above, for every namespace using this NodePool, before uninstalling, not instead of it.

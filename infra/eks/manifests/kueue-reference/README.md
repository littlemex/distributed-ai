# kueue-reference — queue one existing NodePool, opt one namespace in

Reference ClusterQueue/ResourceFlavor/LocalQueue for Kueue (the controller `infra/eks/kueue.tf` always installs). Not applied by Terraform: which NodePool to queue, how much of it to allow, and which namespace may use it are workload-shape-specific, exactly like `accelerator_pools` in `accelerator-pools.auto.tfvars`.

## What this gives you

Submitting more TrainJobs/RayJobs than the quota allows no longer means Karpenter tries to launch nodes for all of them at once (and fails some with `InsufficientInstanceCapacity`, or launches more nodes than you meant to pay for). Instead, Kueue holds the excess as pending Workloads and admits them as earlier ones finish — the same NodePool, the same accelerator_pools definition, just with an admission gate in front of it.

## What this does NOT give you

- **No capacity reservation.** The quota you set is a ceiling on what Kueue will *try* to admit, not a guarantee the NodePool can supply it. A quota the instance types/AZ/Spot pool cannot back looks exactly like an ordinary unschedulable-pod wait.
- **No cross-NodePool sharing.** This example is one ClusterQueue over one NodePool. Kueue's [cohort](https://kueue.sigs.k8s.io/docs/concepts/cohort/) mechanism can share quota across several ClusterQueues; not covered here.
- **No deadline/time-of-day awareness.** Kueue admits by quota and priority, not by how long a job is expected to run or when its window of opportunity closes.

## Usage

```bash
cd infra/eks/manifests/kueue-reference
sed -e 's/__NAMESPACE__/distai/g' \
    -e 's/__NODEPOOL_NAME__/gpu-ddp/g' \
    -e 's/__GPU_QUOTA__/1/g' \
    queue.yaml.tmpl | kubectl apply -f -
```

Substituting `__GPU_QUOTA__` with the real number of GPUs the target NodePool's instance types each carry (times how many you are willing to run concurrently) is the one value worth getting right before applying; see the comment in `queue.yaml.tmpl`.

## Opting a namespace in

`kueue.tf` scopes Kueue's webhooks to namespaces labelled `managed-by-kueue: "true"` (Kueue's own documented ["opt-in namespace management"](https://kueue.sigs.k8s.io/docs/tasks/manage/enforce_job_management/opt_in_namespace_management/) pattern, not this repo's invention) — everything else on the cluster is untouched, which matters on a cluster shared with workloads this repo does not own. `queue.yaml.tmpl` labels the namespace for you as part of applying it; if you are reusing a namespace that already exists, labelling it again is harmless (`kubectl label namespace <ns> managed-by-kueue=true --overwrite`).

## Using the queue

Add the queue-name label to the workload (a TrainJob, in this repo's case):

```bash
kubectl label trainjob <name> kueue.x-k8s.io/queue-name=gpu-ddp
```

or set it at creation time in the object's `metadata.labels`. `charts/experiments`'s `trainjobTrain.queueName` Helm value does this for you (see that chart's README). A TrainJob created *without* this label bypasses Kueue entirely and goes straight to the default scheduler — by design (`managedJobsNamespaceSelector` scopes which namespaces Kueue's webhooks look at, the queue-name label decides whether an individual workload inside that namespace opts in).

## Removing it

```bash
kubectl delete -n distai localqueue gpu-ddp
kubectl delete clusterqueue gpu-ddp-cq
kubectl delete resourceflavor gpu-ddp
```

Deleting a ClusterQueue that still has admitted Workloads is rejected until they finish or are deleted; delete the TrainJobs/RayJobs first. Uninstalling `kueue.tf`'s Helm release entirely removes Kueue's CRDs along with it (see that file's header comment) and takes every ClusterQueue/LocalQueue/ResourceFlavor/Workload with it — do that only after this cleanup, not instead of it.

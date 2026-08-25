# Installing the profiling platform

`infra/scripts/install-profiling.sh` wires the profiling platform onto a cluster that `infra/eks` already
manages. It is the supported way to adopt the platform: one command, re-runnable, and it reads every
Terraform output itself so that no operator has to move values between states by hand.

```bash
export CLUSTER_NAME=my-cluster
export AWS_REGION=us-east-2
export PRODUCER_NAMESPACES=team-a,team-b
infra/scripts/install-profiling.sh
```

## Without a checkout

`infra/scripts/get-profiling.sh` is the same install for someone who does not have this repository
yet. It fetches the tree at a pinned release, installs the `kubectl-accelprof` plugin onto `PATH`,
and then runs the installer inside that tree. The release is written into the script, and the URL is
that release's URL, so the one-liner and the tree it installs cannot drift apart.

```bash
export CLUSTER_NAME=my-cluster
export AWS_REGION=us-east-2
export PRODUCER_NAMESPACES=team-a,team-b
export TF_STATE_BUCKET=my-terraform-state
export TF_STATE_REGION=ap-northeast-1
export TF_STATE_KEY=eks/my-cluster/terraform.tfstate
export TF_STATE_LOCK_TABLE=my-terraform-locks
curl -fsSL https://raw.githubusercontent.com/littlemex/distributed-ai/refs/tags/release/eks-distributed-ai/v0.0.2/infra/scripts/get-profiling.sh | bash
```

The `TF_STATE_*` variables are required on this path and optional on the other one. `backend.hcl` is
environment-specific and untracked, so a fresh clone does not have one to read the state's location
from; from a checkout that has been through `bootstrap-remote-state.sh`, they are read from it. The
region is the state bucket's region, which is not necessarily the cluster's.

The checkout lands in `~/distributed-ai-<release>` (`PROFILING_DIR`) and the plugin in
`~/.local/bin` (`PROFILING_BIN_DIR`). `RUN_INSTALL=0` stops after fetching, for a look at the plan
before anything is applied. Re-running is safe: the checkout is a detached tag, so a newer release's
one-liner installs beside this one rather than moving it. To install a different release, use that
release's URL; overriding `PIN` is for developing the script itself.

## What it installs

| Layer | Contents |
| --- | --- |
| Data layer (`infra/data-layer`) | Per-region trace bucket, MLflow artifact bucket, KMS CMK, S3 Files filesystem and access point, the managed MLflow tracking server, and the producer / reader / janitor IAM roles |
| Cluster (`infra/eks`) | S3 Files mount target and its security group, the `mcp` namespace with the read-only `mcp-reader` ServiceAccount, one Pod Identity association per producer namespace, and the two ECR repositories the platform's images live in |
| Workloads | The `analysis` and `knowledge` MCP servers, deployed by the `mcp-host` chart onto CPU nodes, with the analysis server pinned to the mount's Availability Zone |
| Producer namespaces | In each namespace listed in `PRODUCER_NAMESPACES`: the `accelprof-config` ConfigMap that tells a workload where the platform is, a Role letting a recorder read its own Pod and annotate its own Job, and an hourly check that reports finished producer Jobs with no recording |

One data layer serves many clusters. It owns the shared MLflow tracking server, so adding a second
cluster does not add a second server; the trace bucket is per region, so traces stay next to the
accelerators that produced them.

## Inputs

| Variable | Required | Meaning |
| --- | --- | --- |
| `CLUSTER_NAME` | yes | The existing EKS cluster to wire |
| `AWS_REGION` | yes | Region of the cluster and of its trace bucket |
| `PRODUCER_NAMESPACES` | yes | Comma-separated namespaces whose workloads may collect profiles. This list is the allow-list for writing traces and logging runs |
| `DATA_LAYER_NAME` | no | Which data layer to use, default `mcp`. Reuse is the default |
| `CREATE_DATA_LAYER` | no | Set to `1` to allow creating a data layer that does not exist yet |
| `ANALYSIS_DIGEST`, `KNOWLEDGE_DIGEST` | no | Image digests to deploy. Default: resolve the published `v1-nsys` and `v1` tags |
| `DEV_BUILD` | no | Set to `1` to build both images with the in-cluster BuildKit instead of consuming published digests |
| `PROFILING_ONLY` | no | Apply only the platform's own resources, leaving unrelated cluster drift untouched |
| `ALLOW_UNRELATED` | no | Apply unrelated cluster changes as well |
| `SKIP_ACCEPTANCE` | no | Skip the closing MCP round trip |
| `TF_STATE_BUCKET`, `TF_STATE_REGION`, `TF_STATE_KEY`, `TF_STATE_LOCK_TABLE` | from `backend.hcl` | Where the cluster's Terraform state lives. Required when `infra/eks/backend.hcl` is absent, which is the case in a fresh clone |
| `TF_STATE_BUCKET`, `TF_STATE_REGION`, `TF_STATE_LOCK_TABLE` | no | Where both states live. Read from `infra/eks/backend.hcl` when unset, which suits an operator working from a checkout; a pipeline should pass them explicitly rather than rely on another module's backend file |
| `DATA_LAYER_STATE_KEY` | no | The data layer's state key, when it is not `data-layer/<name>/terraform.tfstate` |

Everything else is fixed or derived, including the `mcp` namespace, the `mcp-reader` and
`mcp-producer` ServiceAccount names, the mount path `/traces`, the Helm release name, the ECR
repository names, the bucket names, and the mount's Availability Zone. These names appear in
Terraform, in the chart and in the producer contract at once, so making them configurable would only
create ways for the three to disagree. The Availability Zone in particular is deliberately not an
input: an S3 Files mount is reachable from one zone only, and a zone supplied by hand drifts from the
mount target that actually exists.

Remote state is required. Both states live in the same bucket under distinct keys: the data layer's
key comes from `DATA_LAYER_NAME`, and the bucket, region and lock table are taken from
`TF_STATE_BUCKET`, `TF_STATE_REGION` and `TF_STATE_LOCK_TABLE` when given, or read from
`infra/eks/backend.hcl` otherwise. Reading another module's backend file is a convenience for a
checkout and not a contract, which is why an explicit value always wins. If
`infra/data-layer/backend.tf` is missing it is installed from the shipped example.

### Where these files live

Anything that spans both Terraform states lives outside them: this document beside
the installer in `infra/scripts/`, because neither
`infra/eks` nor `infra/data-layer` owns an operation that applies both. Everything that only
touches the cluster stays under `infra/eks`: the client and the image build in `scripts/`, the
code that is baked into the platform image in `images/accelprof/`, and the producer guide in
`docs/profiling-producer.md`. Every document other than a README lives in a `docs/`
directory. A second state-spanning script belongs in `infra/scripts/` too.

## Prerequisites

- A cluster managed by `infra/eks`, with remote state configured
  (`infra/eks/scripts/bootstrap-remote-state.sh`).
- Credentials that can apply both states, and `terraform`, `kubectl`, `helm`, `aws`, `python3` and
  `curl` on `PATH`.
- Published platform images, or `DEV_BUILD=1` to build them in-cluster.

## Re-running, and what the guard does

Every phase is either natively idempotent or check-then-act, so re-running is the normal way to
converge: the data layer plan comes back empty, image builds are skipped when the tag is already
published, Helm upgrades in place, and existing ECR repositories are adopted into the state rather
than colliding with it. Nothing is ever destroyed and nothing is rolled back on failure — fix the
cause and run it again.

Before each `apply` the script plans and classifies every change:

- **Record-of-record resources** are the trace buckets, the MLflow artifact bucket, the tracking
  server, the CMK and the S3 Files filesystem and access point. A plan that deletes or replaces one
  of them is refused outright, with no override. Losing run metadata is not recoverable, and it also
  makes every stored prefix look orphaned to a garbage collector.
- **Platform resources** are applied.
- **Unrelated changes** stop the run and are listed. A long-lived cluster accumulates drift that has
  nothing to do with profiling, and an installer must not apply it silently. Re-run with
  `PROFILING_ONLY=1` to converge only the platform, or `ALLOW_UNRELATED=1` to accept everything.

The closing acceptance check opens a port-forward to the analysis server, performs the MCP
initialization handshake and calls `tools/list`, so a successful run means the server answered rather
than merely that a Pod started.

## Recording runs

In each producer namespace, create the ServiceAccount that the Pod Identity association targets:

```bash
kubectl --context "$KUBE_CONTEXT" create serviceaccount mcp-producer -n "$NAMESPACE"
```

Experimenters then need nothing from this repository. `bin/kubectl-accelprof`, on PATH, submits a
profiled run and finds its recording afterwards; see [profiling-producer.md](../eks/docs/profiling-producer.md).

```bash
kubectl accelprof run --alias team1-lora-sweep --image "$MY_IMAGE" -- python train.py --lr 3e-4
```

### Why there is no controller

A producer Job records itself: a container running the platform image waits for the workload beside
it, reads the files it left in a shared volume and logs one MLflow run. Nothing reconciles anything,
so there is no operator to deploy, upgrade or watch — the Job is already the controller Kubernetes
provides, and this workflow is one-shot rather than convergent. The two things a custom resource
would have added are covered without one: the finished Job is cleaned up by
`ttlSecondsAfterFinished`, and the run id is written back onto the Job as an annotation.

That leaves exactly one gap, which no in-Pod component can close: a Pod that disappears before its
recorder runs. The hourly check in each producer namespace reports it. A custom resource becomes
worth revisiting when two of these are true: several Jobs need orchestrating as one unit (a sweep, a
queue), the entry point has grown beyond one client and needs a stable API surface, or the platform
already runs a controller of its own for another reason.

### Why the producer tooling ships in the image

The shim that wraps a command and the recorder that logs the run are baked into the platform image
rather than mounted from a per-run ConfigMap, so that the code and the `accelprof` version it calls
are pinned together by one image digest. They are not part of the `accelprof` package either: they
encode this cluster's contract — how the profiler is invoked, where the shared volume is mounted, how
a Pod reads its own status — which changes with the platform, not with the library. The package owns
the recording API and the analysis server; the platform owns when and where they are called.

### The alias is the unit of everything

An alias is simultaneously the MLflow experiment name and the top-level S3 prefix
(`alias/run_id/`), which makes it the unit of deletion, of retention, of what is visible under the
read-only mount, and of orphan collection. `workload_id`, params and tags are not part of the path.

Use one alias per experiment campaign, named `tenant-series`, and vary `workload_id` and free-form
params inside it:

- Switching campaigns means a new `series`, not a new namespace. A namespace only decides which
  workloads may write at all; it has no bearing on the alias or the storage layout.
- Reusing one alias for every campaign makes campaign-level cleanup a two-step asynchronous dance
  through MLflow deletions, and leaves an experiment with thousands of unrelated runs.
- Giving every repetition its own alias multiplies the deletion and retention units instead, which
  is what the reserved `workload_id` tag exists to avoid.

### What alias separation is not

An alias is a shelf, not a boundary. The producer role can write anywhere in the trace bucket, the
S3 Files access point is rooted at the filesystem root so the reader sees every alias, and the
managed MLflow data plane authorizes per tracking server rather than per experiment. Everyone with
access to the platform can therefore read everyone's runs, metrics and profiles. The platform is
built for a single trust domain on purpose. Hard tenant separation is future work: it means a trace
bucket, CMK, S3 Files filesystem and producer role per tenant, plus prefix-conditioned IAM, and
separate tracking servers when metrics themselves must be confidential.

## Cost, and pausing

The tracking server is billed while it exists, so it stays behind `mlflow_enabled`. To pause the cost
while the platform is idle, stop the server — its state is preserved:

```bash
aws sagemaker stop-mlflow-tracking-server --tracking-server-name "$TRACKING_SERVER_NAME" --region "$AWS_REGION"
```

Do not flip `mlflow_enabled` to `false` for that purpose. That is a teardown: it destroys the server
and its run metadata, and only the S3 artifacts survive. The trace and artifact buckets carry
`prevent_destroy` for the same reason, and the plan guard refuses any plan that would remove them.

## Checking a change to the Job shape

The Job the client submits is embedded in the client, so the rendered manifest is kept as a golden
file and compared by a test that needs no cluster:

```bash
infra/eks/tests/run-render-tests.sh
infra/eks/tests/run-render-tests.sh --update
```

This is deliberately not part of `infra/eks/tests/run-tests.sh`, which exercises a live cluster and
therefore cannot gate every commit. A change to the shape shows up as a golden diff in review.

## Troubleshooting

| Symptom | Cause and remedy |
| --- | --- |
| `403 Request is not authorized` from a producer or the analysis server | The tracking URI points at a serverless MLflow App. Its data plane does not authorize the granular `sagemaker-mlflow:*` actions that the scoped roles hold, so a least-privilege identity can never reach it. The installer refuses an ARN that is not a tracking server, so this indicates a hand-edited value |
| The mount probe fails and the run stops | The read-only S3 Files mount is not working. The probe distinguishes a genuine mount failure, which restarts the EFS CSI node plugin once, from an admission or scheduling failure, which it reports without touching that shared DaemonSet. Inspect `job/mcp-mount-probe` in the `mcp` namespace |
| The analysis Pod stays `Pending` | The mount is reachable from one Availability Zone only and the analysis Pod is pinned there. Confirm that the zone has schedulable CPU nodes |
| The run stops on unrelated cluster changes | Pre-existing drift in the cluster module. Converge only the platform with `PROFILING_ONLY=1`, or accept everything with `ALLOW_UNRELATED=1` |
| An ECR repository already exists | Expected on a cluster that published images before the repositories were managed here. The installer adopts them into the state |
| A record-of-record bucket is planned for creation | The state has lost track of a bucket that exists. The installer adopts the buckets it knows about; a refusal here means a case it does not cover, and importing by hand is the fix — never let a create run against a live bucket |
| A namespace was added to `PRODUCER_NAMESPACES` but its workloads cannot submit | The ConfigMap, Role and check are published per namespace by this installer and a namespace that did not exist during the last run was skipped with a warning. Re-run it |

## Teardown

Remove the workloads and the cluster-side wiring, and leave the record of record alone:

```bash
helm --kube-context "$KUBE_CONTEXT" uninstall mcp -n mcp
terraform -chdir=infra/eks apply -var s3files_enabled=false -var analysis_mcp_enabled=false
```

The data layer is retired separately and deliberately, because that step destroys the tracking server
and its run metadata.

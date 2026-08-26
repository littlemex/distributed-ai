# The cluster contract

Everything `benchctl` needs the cluster to already provide, and who owns each side of it. The
dependency is one way: `benchctl` consumes these values as configuration, and nothing in `infra/`
imports anything from here. Hard-coding the same string on both sides is how the two drift, so each row
names the Terraform output it comes from rather than the literal.

## What `infra/` provides

| Thing | Why it is infrastructure | Terraform output |
| --- | --- | --- |
| A CPU node pool for benchmark clients | Capacity planning. The client must not share a node with the server whose latency it measures, and it needs enough disk to hold a benchmark image — a run once evicted a node by filling it | `bench_node_label`, `bench_node_taint` |
| The taint on that pool | Keeps other workloads off it, so a measurement is not competing for CPU | `bench_node_taint` |
| An EFS filesystem and access point for artifacts | Exists before any run, shared read-write by many pods, and outlives every Job. A pod is not a place results can live: one has already taken a finished episode's log with it when its node was consolidated | `artifact_storage_class`, `artifact_filesystem_id` |
| The StorageClass, or a static PV bound to the access point | Cluster-scoped, admin-owned | `artifact_storage_class` |
| The IAM role and its trust policy for the harness's service account | An AWS resource. Lives next to `infra/data-layer/iam.tf` | `bench_irsa_role_arn` |
| The namespace | Cluster-scoped | `bench_namespace` |

## What `benchctl` provides

| Thing | Why it is the workload's | Where |
| --- | --- | --- |
| `nodeSelector`, `tolerations`, affinity | The consumer's side of the label and taint above | `jobs/*.yaml` |
| `resources.requests/limits.ephemeral-storage` | How much disk *this* Job needs, which only the Job knows. `submit` refuses a Job without it | `jobs/*.yaml` |
| The PVC | A statement of what this workload requires, versioned with the Jobs that mount it | `jobs/*.yaml` |
| The ServiceAccount manifest, annotated with the role ARN | A Kubernetes object attached to the workload | `jobs/*.yaml` |
| `karpenter.sh/do-not-disrupt` on both the client and the server pods | Execution semantics. A replica disappearing mid-run makes every number from that run worthless, so `submit` sets it on the serving Deployment and `collect` removes it | `benchctl/orchestrator.py` |
| Job templates, retry and concurrency behaviour, artifact layout | The bench's execution semantics | `jobs/`, `benchctl/` |

## The names, fixed as an interface

IRSA trust has to name a namespace and a service account, so those two strings are part of the contract
and may not be changed on one side alone.

```
namespace:        bench
service account:  benchctl
artifact root:    /artifacts            (the PVC's mount path inside every Job)
```

## Artifact layout

Fixed, because `score` has to find what `submit` wrote without being told, and because score-only reruns
must never touch a response.

```
/artifacts/serving/{digest}.json                      # written by serving/scripts/deploy.sh
/artifacts/runs/{run_id}/manifest.json                # the expanded, immutable run spec
/artifacts/runs/{run_id}/{cell_id}/request.jsonl
/artifacts/runs/{run_id}/{cell_id}/response.jsonl
/artifacts/runs/{run_id}/{cell_id}/trace.jsonl        # perf cells; raw sglang JSONL kept alongside
/artifacts/runs/{run_id}/{cell_id}/score.{version}.jsonl
/artifacts/runs/{run_id}/{cell_id}/cost.jsonl
/artifacts/runs/{run_id}/{cell_id}/raw/               # untouched tool output
```

`score` appends a new version rather than overwriting, so a scorer can be corrected without spending a
GPU again — which matters most for the judge-based scorers, where the prompt is the thing being
iterated on.

## Verification, not trust

`submit` reads `/artifacts/serving/{digest}.json`, asks the live server for `/v1/models` and its engine
configuration, and aborts on any mismatch. This exists because a set of measurements was once taken
against a configuration different from the one the notes recorded — prefix caching was believed on and
the engine had quietly declined it. The manifest therefore carries every engine flag, not a summary:
`enable_prefix_caching` alone decides whether a whole family belongs on the box.

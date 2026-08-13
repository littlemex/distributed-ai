# EKS Regression Tests

This directory is the regression test harness for the Terraform and Karpenter module in `infra/eks`. It organizes the cluster smoke tests into a tiered, declarative suite (a registry of tests tagged by suite and layer) that feature PRs extend by adding their own tests — one function plus one registry line. Execution is namespace-isolated.

## Suites

Suites are cumulative: `baseline ⊂ coverage ⊂ full`. Each test declares the smallest suite that includes it.

| Suite | Includes | Purpose |
|---|---|---|
| `baseline` | Static Terraform validation, read-only cluster checks, and the workshop smoke tests (Karpenter, CSI, device plugins, Trainer, storage mount) | Fast confidence that the workshop path still works |
| `coverage` | Everything in `baseline`, plus the static and isolated live-mutating checks that feature PRs register | Regression coverage for a feature without launching accelerator nodes |
| `full` | Everything in `coverage`, plus GPU launch, `nvidia-smi`, CUDA, and GPU storage | End-to-end accelerator validation |

Registration order in `registry.sh` is execution order. Section headers are emitted automatically at layer boundaries.

## Requirements

The harness prerequisites are `kubectl`, `aws`, and `envsubst`. Terraform, Helm, jq, and Python are declared per test in `registry.sh`; if an optional tool is missing, only that test is reported as `SKIP`.

`kubectl` must point at the cluster managed by this checkout. The cluster name and AWS region are derived from Terraform outputs unless flags override them.

## Usage

```bash
cd infra/eks/tests

# Default: baseline suite.
./run-tests.sh --profile <profile>

# Coverage suite (static + isolated live-mutating checks), no GPU nodes.
./run-tests.sh --suite coverage --profile <profile>

# Full suite, including GPU node launch.
./run-tests.sh --suite full --profile <profile>

# Print the registry without requiring a cluster.
./run-tests.sh --list
```

Compatibility aliases are still supported:

| Alias | Effect |
|---|---|
| `--with-gpu` | Adds the `gpu` layer to the selected suite |
| `--with-hardening` | Raises the suite to at least `coverage` |
| `--skip-static` | Skips the `static` layer |

Common flags:

| Flag | Description |
|---|---|
| `--suite <baseline\|coverage\|full>` | Selects the suite |
| `--skip-layer <static\|live-ro\|live-mut\|gpu>` | Skips a layer; repeatable |
| `--namespace NAME` | Uses a test namespace; all namespaced live-mutating resources stay there |
| `--cluster-name NAME` | Overrides Terraform-derived cluster name |
| `--region REGION` | Overrides Terraform-derived AWS region |
| `--profile PROFILE` | Adds an AWS CLI profile to AWS calls |
| `--gpu-count N` | Sets the GPU count requested by the smoke pod |
| `--gpu-nodepool NAME` | Overrides the Terraform-derived NVIDIA NodePool |
| `--timeout-static SEC` | Overrides the static test timeout |
| `--timeout-base SEC` | Overrides the base live test timeout |
| `--timeout-gpu SEC` | Overrides the GPU test timeout |
| `--keep-ns` | Leaves the test namespace for inspection |

## Test Layers

| Layer | Behavior |
|---|---|
| `static` | Runs Terraform console, Terraform validate, Python unit tests, or Helm render checks without touching the cluster |
| `live-ro` | Reads cluster state only |
| `live-mut` | Creates isolated resources in the test namespace, plus namespace-derived test PVs |
| `gpu` | Launches a GPU node via Karpenter and schedules GPU workloads in the test namespace |

## Adding a Test

Add tests in exactly two steps:

1. Add `test_<name>()` to the appropriate file in `tests/cases/`.
2. Add one `register_test` line to `tests/registry.sh` with the test name, function, minimum suite, layer, timeout, and optional tools.

The registry handles suite selection, layer skipping, optional-tool skips, section headers, timeouts, and summary reporting.

## Value Derivation

The harness avoids cluster-specific literals. Cluster name and region come from Terraform outputs or explicit flags. The GPU NodePool is selected from the live cluster, with `var.accelerator_pools` used only as a last-resort fallback. Storage clone sources are selected by CSI driver, and test PV names are derived from the test namespace.

If a future test needs an AWS account ID, derive it at runtime with `aws sts get-caller-identity`; do not place account IDs in test source.

## Isolation

Live-mutating tests create namespaced resources only in `${NAMESPACE}`. Cluster-scoped PVs are namespace-derived test clones and are pre-bound in both directions: the PV has a `claimRef`, and the PVC has a `volumeName`. The harness only ever deletes a namespace or PV carrying `app.kubernetes.io/managed-by=eks-regression-tests`, so pointing `--namespace` at a pre-existing workload never tears it down. A feature test that must create a resource outside `${NAMESPACE}` should clean it up with an `EXIT`/`TERM` trap (see the guidance in the case files).

## Scope and Exclusions

This harness ships the workshop smoke tests: Terraform validation, control plane / system nodes / Karpenter / CSI drivers / device plugins / Trainer readiness, storage mount over cloned FSx and OpenZFS PVs, and GPU node launch + `nvidia-smi` + CUDA + GPU storage. Feature-specific tests (for example accelerator hardening) are added by their own PRs through the registry.

EFA workload execution and Capacity Blocks are excluded: they require instance capacity that is not reliably available on demand in a test environment.

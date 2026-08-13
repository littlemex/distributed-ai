# EKS Regression Tests

This directory contains the regression test suite for the Terraform and Karpenter module in `infra/eks`. The suite extends the original smoke harness with static checks and opt-in hardening coverage while keeping the same namespace-isolated execution model.

## Suites

| Suite | Includes | Purpose |
|---|---|---|
| `baseline` | Static Terraform validation, read-only cluster checks, and the original smoke tests | Fast confidence that the workshop path still works |
| `coverage` | Everything in `baseline`, plus hardening static checks and isolated live-mutating checks | Regression coverage for kubelet headroom rendering, stuck-node reaper safety, and the Neuron compile-cache EFS PVC (dynamic access points) |
| `full` | Everything in `coverage`, plus GPU launch, CUDA, GPU storage, and live kubelet headroom checks | End-to-end accelerator validation |

Registration order in `registry.sh` is execution order. Section headers are emitted automatically at layer boundaries.

## Requirements

The harness prerequisites are `kubectl`, `aws`, and `envsubst`. Terraform, Helm, jq, and Python are declared per test in `registry.sh`; if an optional tool is missing, only that test is reported as `SKIP`.

`kubectl` must point at the cluster managed by this checkout. The cluster name and AWS region are derived from Terraform outputs unless flags override them.

## Usage

```bash
cd infra/eks/tests

# Default: baseline suite.
./run-tests.sh --profile <profile>

# Hardening coverage without GPU tests.
./run-tests.sh --suite coverage --profile <profile>

# Full suite, including GPU launch and live kubelet checks.
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
| `gpu` | Schedules GPU workloads in the test namespace and reads kubelet `/configz` from selected nodes |

## Adding a Test

Add tests in exactly two steps:

1. Add `test_<name>()` to the appropriate file in `tests/cases/`.
2. Add one `register_test` line to `tests/registry.sh` with the test name, function, minimum suite, layer, timeout, and optional tools.

The registry handles suite selection, layer skipping, optional-tool skips, section headers, timeouts, and summary reporting.

## Value Derivation

The suite avoids cluster-specific literals. Cluster name and region come from Terraform outputs or explicit flags. The GPU NodePool is selected from the live cluster, with `var.accelerator_pools` used only as a last-resort fallback. The stuck-node reaper namespace is discovered from the live CronJob name rendered by Terraform. Storage clone sources are selected by CSI driver, and test PV names are derived from the test namespace.

If a future test needs an AWS account ID, derive it at runtime with `aws sts get-caller-identity`; do not place account IDs in test source.

## Isolation

Live-mutating tests create namespaced resources only in `${NAMESPACE}`. Cluster-scoped PVs are namespace-derived test clones and are pre-bound in both directions: the PV has a `claimRef`, and the PVC has a `volumeName`.

The Neuron compile-cache tests provision dynamic EFS access points via namespaced PVCs in `${NAMESPACE}`; each is cleaned up only if the released PV's `claimRef` still points back at the test PVC, and the backing EFS access point is deleted afterward.

The reaper dry-run job is the only live-mutating test outside `${NAMESPACE}` because it must run from the reaper CronJob namespace. It uses a unique Job name, requires dry-run mode, captures NodeClaims before and after, asserts they are unchanged, and deletes the Job afterward.

## Scope and Exclusions

The suite covers the core workshop path, storage smoke tests, GPU smoke tests, kubelet headroom rendering and live application, stuck-node reaper safety, and the Neuron compile-cache EFS PVC (dynamic access points, shared by serving and training) rendering and binding.

EFA workload execution and Capacity Blocks are excluded. They require instance capacity that is not reliably available on demand in a test environment. Reaper tests target a standard spot or on-demand GPU pool rather than a Capacity Block pool.

# EKS Regression Tests

This directory is the regression test harness for the Terraform and Karpenter module in `infra/eks`. It organizes the cluster smoke tests into a tiered, declarative suite (a registry of tests tagged by suite and layer) that feature PRs extend by adding their own tests — one function plus one registry line. Execution is namespace-isolated.

Two kinds of check live here, and both matter:

- **Readiness checks** (`live-ro`, e.g. `karpenter`, `csi-drivers`, `device-plugins`) assert the platform underneath the workshop is healthy. When a scenario fails, a red readiness check means "the platform is broken"; a green one narrows the failure to the chart or the workshop command itself.
- **Scenarios** (`tests/scenarios/<chapter>/`) run the SAME chart and commands a workshop chapter documents — e.g. Basic07's `helm template ... gpuServingVllm ... | kubectl apply` followed by a `/v1/models` call. A scenario is `deploy.sh` + `verify.sh` + `teardown.sh` plus a `values.yaml`; the chapter and the test both point at the same files, so there is one source of truth for "what the workshop actually runs" and a broken chart is caught here, not just in a reader's terminal.

For workloads a scenario would be too expensive to run on every PR (GPU/Trainium capacity, region-specific Capacity Blocks), the corresponding chart is still rendered and asserted with `helm template` in the `static` layer — no cluster needed — under `tests/cases/chart-contract.sh`. This is cheap enough to run on every PR and catches most ways a serving chart can break (missing Deployment/Service, an unresolved template value, the wrong accelerator resource key, a missing Service port) even where the live scenario cannot run.

## Suites

Suites are cumulative: `baseline ⊂ coverage ⊂ full`. Each test declares the smallest suite that includes it.

| Suite | Includes | Purpose |
|---|---|---|
| `baseline` | Static Terraform validation, read-only cluster checks, and the workshop smoke tests (Karpenter, CSI, device plugins, Trainer, storage mount) | Fast confidence that the workshop path still works |
| `coverage` | Everything in `baseline`, plus the static and isolated live-mutating checks that feature PRs register | Regression coverage for a feature without launching accelerator nodes |
| `full` | Everything in `coverage`, plus GPU launch, `nvidia-smi`, CUDA, GPU storage, and the Basic07 GPU-serving scenario | End-to-end accelerator validation |

There is one standalone suite outside this ladder:

| Suite | Includes | Purpose |
|---|---|---|
| `neuron` | Only the `neuron` layer (the Basic09 Trainium-serving scenario, vLLM Neuron plugin) | Validate a Trainium node end to end, in isolation |

`neuron` is intentionally NOT part of `baseline`/`coverage`/`full`: it requires a Trainium node backed by a region-specific Capacity Block, which most environments lack, so bundling it into the tiered suites would make them fail wherever that capacity is absent. Run it on its own with `--suite neuron`. Because that invocation is explicit, it does not silently skip when the prerequisite is missing: if no node advertises `aws.amazon.com/neuron`, the test fails with an actionable message (bring up a Capacity-Block trn2 nodegroup first). Its chart (`neuronVllmPlugin`) is still covered on every PR by the static contract check above.

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

# Full suite, including GPU node launch and the Basic07 GPU-serving scenario.
./run-tests.sh --suite full --profile <profile>

# Standalone Trainium suite (Basic09), for a cluster with a trn2 Capacity-Block node.
./run-tests.sh --suite neuron --profile <profile>

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
| `--suite <baseline\|coverage\|full\|neuron>` | Selects the suite (`neuron` is standalone; see above) |
| `--skip-layer <static\|live-ro\|live-mut\|gpu\|neuron>` | Skips a layer; repeatable |
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
| `neuron` | Runs the Trainium serving scenario on an existing trn2 node; selected only by `--suite neuron` |

## Adding a Test

Add tests in exactly two steps:

1. Add `test_<name>()` to the appropriate file in `tests/cases/`.
2. Add one `register_test` line to `tests/registry.sh` with the test name, function, minimum suite, layer, timeout, and optional tools.

The registry handles suite selection, layer skipping, optional-tool skips, section headers, timeouts, and summary reporting.

## Adding a Workshop Scenario

When a chapter's main value is deploying and using a workload (not just checking that infrastructure exists), add a scenario instead of a plain live test:

1. Create `tests/scenarios/<chapter>/` with `values.yaml` (the chart values the chapter documents), `deploy.sh` (render + apply + wait for rollout), `verify.sh` (exercise the workload — e.g. hit its API — and assert non-trivial output), and `teardown.sh` (remove what `deploy.sh` created).
2. Add a `test_<name>()` in `tests/cases/` that calls the three scripts in order, with `EXIT`/`TERM` traps to guarantee teardown, and `register_test` it as usual.
3. Have the chapter's own command blocks be exactly what `deploy.sh`/`verify.sh` run — the scenario is the single source of truth for "what the workshop actually runs", so a broken chart or a chapter's stale command is caught here.

## Value Derivation

The harness avoids cluster-specific literals. Cluster name and region come from Terraform outputs or explicit flags. The GPU NodePool is selected from the live cluster, with `var.accelerator_pools` used only as a last-resort fallback. Storage clone sources are selected by CSI driver, and test PV names are derived from the test namespace.

If a future test needs an AWS account ID, derive it at runtime with `aws sts get-caller-identity`; do not place account IDs in test source.

## Isolation

Live-mutating tests create namespaced resources only in `${NAMESPACE}`. Cluster-scoped PVs are namespace-derived test clones and are pre-bound in both directions: the PV has a `claimRef`, and the PVC has a `volumeName`. The harness only ever deletes a namespace or PV carrying `app.kubernetes.io/managed-by=eks-regression-tests`, so pointing `--namespace` at a pre-existing workload never tears it down. A feature test that must create a resource outside `${NAMESPACE}` should clean it up with an `EXIT`/`TERM` trap (see the guidance in the case files).

## Scope and Exclusions

This harness ships the workshop smoke tests: Terraform validation, control plane / system nodes / Karpenter / CSI drivers / device plugins / Trainer readiness, storage mount over cloned FSx and OpenZFS PVs, and GPU node launch + `nvidia-smi` + CUDA + GPU storage. It also ships the workshop's own serving scenarios: the Basic07 GPU-serving chart (`gpuServingVllm`) end to end in `full`, and the Basic09 Trainium-serving chart (`neuronVllmPlugin`) end to end in the standalone `neuron` suite; both charts are additionally render-checked on every PR via `chart-contract.sh`. Feature-specific tests (for example accelerator hardening) are added by their own PRs through the registry.

EFA workload execution is excluded from the tiered suites: it requires instance capacity that is not reliably available on demand. Capacity-Block-backed Trainium serving is covered by the standalone `neuron` suite (see above), which is opt-in precisely because that capacity is region specific.

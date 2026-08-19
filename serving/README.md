# serving/ — reusable model-serving references

`serving/` is the permanent (non-dated) home for **model-serving stacks** that run on top
of the cluster built by `infra/eks`. It is the second permanent top-level directory
(alongside `infra/`); everything else in this repo is a dated experiment
(`YYYY-MM-DD-<topic>/`). Adding this directory changes the repo's "only `infra/` is
permanent" convention deliberately — see "Promotion rule" below.

## Vocabulary (fixed)

- **stack** — the first level (`serving/vllm/`, later `serving/sglang/`, `serving/trtllm/`).
  A stack is the unit where a Helm chart + (optional) image + scripts are reused together.
  It is *not* the same as an "engine": `llm-d` wraps vLLM and would be its own stack, not a
  sibling of `vllm`.
- **model** — a `serving/models/<normalized-id>.yaml` file holding **facts only** (things
  mechanically verifiable from the model's `config.json`, tokenizer, and license). Models are
  not directories.
- **topology** — `tensorParallelSize` / `pipelineParallelSize`, rendered by the stack's chart
  (single-node TP today; multi-node LeaderWorkerSet is a future, EFA-capable-pool concern).

Model facts are shared under `serving/models/`; engine-specific tuning for the same model
lives in `serving/<stack>/overlays/<normalized-id>.yaml`. This keeps a model's facts from
being copied when a second engine serves it.

Normalized id: derive the filename from the `model_id` (`Qwen/Qwen3.8-27B` → `qwen3.8-27b`).
The transformers architecture identifier (e.g. `qwen3_5`) is a fact field, never the filename.

## What is infra vs what is here

The boundary is the one stated in `infra/eks/docs/CONTRACT-serving.md`: if it cannot be
swapped without rebuilding the cluster it is infra; if `kubectl delete` removes it, it is a
workload and lives here. This directory therefore contains Deployments/Services, per-model
values, and `up.sh`; it never creates NodePools, CSI drivers, or PVs. The GPU pool a stack
targets is selected by its `node-role` label (a pool capability name owned by infra), never
by a hardcoded instance type.

## Non-goals

- Multi-node / disaggregated serving (needs EFA-capable pools; future).
- Neuron serving (see the book's Basic09 `neuronVllmPlugin` in `infra/eks/charts/experiments`).
- A CD controller, autoscaling (HPA/KEDA), or shared multi-user ingress. `kubectl port-forward`
  is for demos only.
- Relationship to `infra/eks/charts/experiments`: those are the book's teaching templates
  (single GPU, small model) and are frozen. `serving/` is the general reference they point to.

## Promotion rule

- Only a skeleton that has been reproduced in **two or more** dated experiments gets promoted
  here, by extraction.
- Do not start new development directly under `serving/`; do experiments in a dated directory
  and extract.
- References flow one way: a dated experiment may fork `serving/`; a change to `serving/` comes
  only via an extraction PR.
- Permanent top-level directories stop at `serving/`. If training later needs a permanent home,
  add a sibling top (`training/`), not an `apps/` umbrella.

## Stacks

- [`vllm/`](vllm/README.md) — single-node vLLM OpenAI-compatible serving (GPU).

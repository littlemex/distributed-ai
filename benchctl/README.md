# benchctl — measure what a family costs, on which layer, at which operating point

`benchctl` answers one question repeatedly: **which families of work can the self-hosted box absorb at
an acceptable quality, and what does that save off the API bill?** It is the instrument for the
objective the routing work is optimising,

```
net_offload_value = Σ a_i [ p_i·C_api_i − C_validate_i − L_penalty_i ] / Σ a_i·S_box_i
priority_k        = LCB(p_k)·C_api_k / UCB(S_k)
```

where `p_i` is the probability the box meets the family's quality floor, `C_api_i` is what that family
would have paid an API, and `S_box_i` is the box time it consumes.

## Why this is not in `infra/`

`infra/` holds resources whose lifecycle completes with `terraform apply` and whose truth lives in
tfstate. `benchctl` is a Python application whose truth is this code and its tests. Mixing them would
mean Terraform reviewers reading scorer bug fixes with plan-diff eyes, and a schema addition carrying
the weight of an infrastructure change. The rule, stated once so it does not need re-arguing:

> **`infra/` is for the desired state of cloud and cluster resources that must exist before any
> workload runs and whose lifecycle Terraform owns. Anything that runs on them or consumes them stays
> out, however permanent it is.**

What `benchctl` needs from `infra/` is real but small — a CPU node pool it can request
ephemeral-storage from, and an EFS filesystem for artifacts. That capacity is infrastructure. The Jobs,
the schemas and the scoring are not. The interface between them is written down in
[`docs/cluster-contract.md`](docs/cluster-contract.md) and flows one way: `benchctl` consumes Terraform
outputs, and Terraform never learns about `benchctl`.

## The shape of a measurement

A run is **two cells**, and the split is deliberate rather than hidden.

| Cell | What it runs | Concurrency | Produces |
| --- | --- | --- | --- |
| `quality` | this harness's task plugins against one layer | low, deterministic (temperature 0) | `request`, `response`, `score` |
| `perf` | a load generator against the same layer | the operating point (c=16, …) | `trace`, `cost` |

For the perf cell there are two instruments, and which one applies depends on whether the family's
prompts can be synthesised. `benchctl/perf_cell.py` sweeps controlled shapes — a stated input and output
length, closed loop for capacity and open-loop Poisson for service level — which no trace corpus can
give, because a corpus has the lengths it has. [`instruments/agentx`](instruments/agentx/) borrows
SemiAnalysis AgentX for the agentic family, where the shape that matters is a real multi-turn
conversation and the property that matters is prefix reuse. Its numbers are taken with their flags and
their aggregator so they sit on the same axis as numbers published for other hardware.

They are joined on `(family, operation_point_id, serving_manifest_digest)` — **not** per request. The
quantity the objective needs, `S_box_i`, is the box time a family's requests consume *at the operating
concurrency*, which is a distribution and not a property of one call. Measuring it at one request in
flight would be the wrong number, so the perf cell exists separately and `benchctl report` joins the
two distributions per cell.

## Declarations

Five, all YAML, all in git. Results are not in git: EFS is the truth for those.

| Declaration | Answers |
| --- | --- |
| `suite` | which family, which items, which floor, which comparison layer |
| `layer` | a servable thing: an API model with its price, or the box with its serving manifest |
| `policy` | routing and cascade: which layer first, what accepts, what escalates |
| `operation_point` | the knobs — concurrency, shape, replicas, and the serving reference |
| `run` | which cells to submit, with which seeds, against which serving digest |

## CLI

```bash
benchctl validate  specs/runs/classification-seed.yaml
benchctl submit    specs/runs/classification-seed.yaml     # expands to one Job per cell
benchctl collect   --run-id 2026-08-27-classification-seed
benchctl score     --run-id ... --scorer schema-exact@v2   # re-reads responses, no GPU
benchctl report    --run-id ...
```

`submit` refuses a run whose serving manifest does not match the live server, and refuses a Job with no
`ephemeral-storage` request. Both refusals exist because both failures happened: a measurement was once
taken against a configuration different from the one recorded, and a benchmark Job once evicted a node
by filling its disk with a container image.

## Status

The boundary, the declarations and the cluster contract are in place. The task plugins per family, the
scorers and the Job templates are being filled in family by family, in the order the design settled on:
verifiable short-input classification first because it is the cheapest way to prove the plumbing, batch
long-document extraction alongside it because that is where the money is — the box's input is a quarter
of the cheapest API's while its output is only 18% cheaper, so the saving scales with input length.

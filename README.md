# distributed-inference
distributed inference sample

## What is at the top level

Two kinds of directory, and the difference is the date.

| Kind | Naming | What it is | Rewritten? |
| --- | --- | --- | --- |
| Experiment record | dated, e.g. `2026-08-24-mom-vsr-eks-benchmark/` | The question asked on that day, the configuration it ran, and what came out | No. Append only. It is the record of what was true then |
| Maintained asset | no date, e.g. `serving/`, `benchctl/`, `infra/` | Code and declarations whose truth is the current version | Yes. It is what is true now |

A permanent asset does not belong in a dated directory: the date becomes a lie the moment something
starts depending on it. When a dated experiment produces something reusable, the reusable part is
promoted to a date-less directory and the dated one is frozen with a pointer — not renamed, because
renaming breaks history and links.

`infra/` is the narrowest of the assets, and the rule that keeps it that way is:

> **`infra/` is for the desired state of cloud and cluster resources that must exist before any
> workload runs and whose lifecycle Terraform owns — resources for which tfstate is the truth.
> Anything that runs on them or consumes them stays out, however permanent it is.**

So the node pool a benchmark needs is `infra/`; the benchmark is `benchctl/`. The interface between
them is one-way and written down in [`benchctl/docs/cluster-contract.md`](benchctl/docs/cluster-contract.md).

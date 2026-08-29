# AgentX, as an instrument this repository borrows rather than reimplements

[SemiAnalysis AgentX](https://github.com/SemiAnalysisAI/InferenceX) is AIPerf's
`inferencex-agentx-mvp` scenario replaying 393 anonymised Claude Code traces: multi-turn agentic
coding, tens of thousands of input tokens per turn, and a corpus whose defining property is that a
prefix cache could serve 94% of those tokens.

## Why it is here and not written from scratch

`perf_cell.py` has said since it was written that it was a stand-in for a real instrument. This is one.
Two things it provides that no home-grown loop can:

* **A corpus.** 68,266 requests of real agentic traffic, 99.15% of whose tokens are input. That figure
  independently reproduces the 99.5% this project measured on its own SWE-bench episodes, which is how
  a workload characterisation stops being a property of one scaffold.
* **Comparability.** Numbers taken with their flags, their scenario and their aggregator sit on the same
  axis as numbers published for other hardware. Numbers taken with mine do not.

## The boundary

| | Owns |
| --- | --- |
| AgentX / AIPerf | the traces, the replay semantics, the load generation, the statistics |
| this directory | pinning the version, standing it up in-cluster, pointing it at the box, recording what deviated |
| `benchctl` | the artifact contract and the box-cost accounting laid over their output |

Their `build_replay_cmd` flag set is copied verbatim, including the values, because a benchmark run with
different flags is a different benchmark. Their aggregator is invoked rather than reimplemented, so the
percentiles are theirs. What is added on top is only what is genuinely this project's: the box's hourly
cost, and the comparison against what an API would have billed.

Every run writes `provenance.json` with both commits, the corpus, the concurrency, whether the scenario's
900-second minimum was met, and an explicit list of deviations — starting with the fact that this box is
not a published AgentX platform, so its absolute numbers are not commensurate with the dashboard's.

## Running one arm

```bash
./scripts/submit-agentx.sh <name> <concurrency> <duration_s>
```

Concurrency and duration are the arm; everything else is fixed so two arms differ only in the swept
variable. The per-replica Prometheus URLs are resolved at submit time rather than in the pod, because the
alternative is granting the benchmark client RBAC to look up the server it is measuring. Both replicas
are scraped: the Service would answer for one of two, and a cache hit rate averaged over half a box is
not the box's.

A duration under 900 seconds is a smoke test. The script passes `--unsafe-override`, the scenario marks
the run invalid for submission, and `provenance.json` records `canonical: false`.

## Sizing, learned the hard way

`ephemeral-storage` is requested at 60 Gi and limited at 120 Gi, and the scratch volume is separate from
the artifact volume. The corpus is 0.57 GB on disk but AIPerf reconstructs every turn's full prompt and
memory-maps the result; a run of this shape used 5.1 GB. An earlier benchmark image on this cluster filled
a node's disk and got its own Job evicted, which is why the request is explicit rather than inherited.

The client also has `requiredDuringScheduling` anti-affinity against the serving pods. A load generator
sharing a node with the server whose latency it reports is measuring itself.

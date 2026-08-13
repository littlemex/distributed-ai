# Design: Remote-MCP Profiling & Kernel-Tuning Platform

**Status:** Draft v4 (investigation + overall design; pre-implementation). Revised after two
adversarial design-review rounds and a pivot to **managed MLflow** as the experiment-management
backbone.
**Scope repo:** `distributed-ai`
**Related existing machinery:** `infra/eks` (Terraform cluster), `infra/bench` (accelerator
parity harness).

## 1. Context and goals

Repeatable loop across NVIDIA GPU and AWS Neuron accelerators:

1. Run a workload and **profile** it with *whatever tool fits* (GPU: Nsight Systems/Compute,
   DCGM; Neuron: `neuron-profile`, `neuron-monitor`; or any other OSS tool).
2. **Register** the run in one experiment-management framework — the same framework for GPU
   (one region) and Neuron (another region) — so results can be analyzed together later.
3. Expose an in-cluster **remote MCP** server that reads the registered runs + their trace
   artifacts and answers kernel-tuning questions from a local machine (Claude Code).
4. Reuse the existing `infra/bench` judging so **accuracy, performance, and cost** line up per
   run.

**Design center (the load-bearing requirement).** The *common, shared* thing is **experiment
management + stable IDs** across separate regions/clusters. The *variable, per-user* thing is
**measurement** — any tool — absorbed **ETL-style** into the common framework by whoever runs
the measurement. So we do not hard-wire a self-built measurement pipeline; we standardize the
experiment/run identity and the logging convention, and let tool outputs be adapted in.

**Backbone decision: ride managed MLflow, do not build our own tracker.** We use the
**SageMaker serverless MLflow App** (`aws_sagemaker_mlflow_app`) as the experiment-management
backbone. It gives us, with almost no code: server-assigned stable run IDs, experiments/runs/
params/metrics/tags, an artifact store, a query API, and a UI — and one central instance that
clusters in *different regions* log to. This directly satisfies "unify GPU (Tokyo) and Neuron
(Melbourne) under one framework" and keeps our implementation small (prefer existing systems).

**Hard constraints / facts:**

- Local access via `kubectl port-forward` only for the MCP; **the MLflow UI uses a presigned
  URL API, no ALB/CloudFront**.
- Reuse the existing in-cluster Prometheus for cluster health; **experiment analysis lives in
  MLflow**, not Prometheus.
- FSx for Lustre exposes only a **single static PV** (`infra/eks/fsx.tf`).
- **GPU and Neuron are separate clusters in separate regions.** MLflow is central (one region);
  clients log cross-region.
- The whole platform (MLflow App, MCP, buckets' writers) is **opt-in** — non-profiling
  workloads pay nothing. MLflow itself is a paid resource, so it is gated `mlflow_enabled=false`.

**Non-goals (deferred):** Nsight AI's CUDA-doc RAG (out of scope until Phase 5); no
cross-cluster federated Prometheus; no self-hosted MLflow server + database (the managed App
removes that ops burden — the whole point of the pivot).

## 2. Architecture

```
[ Local / Claude Code ]
   │ MLflow UI:  aws sagemaker create-presigned-mlflow-tracking-server-url → browser (no ALB)
   │ MCP:        kubectl port-forward 8080:80 → mcp-gateway-registry (semi-permanent)
   │ GPU trace:  MCP get_presigned_url → download → open in LOCAL Nsight (no in-cluster UI)
   ▼
                    ┌──────────────────────────────────────────────┐
                    │ SageMaker serverless MLflow App (central,     │
                    │ region=Tokyo; aws_sagemaker_mlflow_app)       │
                    │  - server-assigned run_id (the shared ID)     │
                    │  - experiments/runs, params, metrics, tags    │
                    │  - artifact store = OUR S3 (small artifacts)  │
                    │  - UI via presigned URL; idle-cost = zero      │
                    └───────────▲──────────────────────▲────────────┘
                 SigV4 (Pod Identity) log runs      SigV4
   ┌────────────────────┴─────────┐      ┌──────────┴───────────────────┐
   │ EKS GPU cluster (Tokyo)      │      │ EKS Neuron cluster (Melbourne)│
   │  producer Job: workload +    │      │  producer Job: workload +     │
   │   nsys/ncu/DCGM  → ETL →      │      │   neuron-profile → ETL →      │
   │   MLflow run (tags+metrics)  │      │   MLflow run (tags+metrics)   │
   │   GB trace → OUR S3 (region) │      │   GB trace → OUR S3 (region)  │
   │  profiler-mcp (reads MLflow  │      │  monitoring: kube-prom (health)│
   │   + our S3), behind gateway  │      └───────────────────────────────┘
   │  monitoring: kube-prom       │
   └──────────────────────────────┘
        GB traces (region buckets, referenced from the MLflow run by S3 URI)
        s3://<acct>-mcp-traces-<region>/exp=<experiment>/case=<case>/run=<mlflow_run_id>/trace...

  Cross-accelerator comparison = MLflow search_runs(experiment, filter tags accelerator/case_id)
  over frozen runs — no cross-region tensor shipping, no custom comparison store, no live
  Prometheus across regions.
```

The GPU/Neuron asymmetry is hidden in the MCP adapter module + the ETL adapters; tags/metrics
above are device-neutral.

### 2.1 Feature gating and ownership (three states)

Gating is by **resource ownership**, never by flags mutating shared resources.

**(1) Data-layer state — separate Terraform state (mandatory; S3+KMS backend):**

| Item | Gating | Notes |
|---|---|---|
| `mcp-traces-<region>` buckets (GB traces), `mlflow-artifacts` bucket (MLflow's artifact store) | unconditional, `prevent_destroy`, lifecycle at creation | separate state so cluster `terraform destroy` never deletes the record of record (round-2 R2-10). |
| **`aws_sagemaker_mlflow_app`** (serverless MLflow App) | **`mlflow_enabled = false`** | paid resource → opt-in. `artifact_store_uri` = the artifacts bucket; `role_arn` = an IAM role it uses for that bucket. Idle-cost zero (serverless). Central in Tokyo. |

**(2) Base-cluster state (`infra/eks`) — durable capability:**

| Item | Gating | Notes |
|---|---|---|
| S3/FSx/EFS CSI drivers, EKS **Pod Identity** agent | unconditional | permanent capability. |
| Pod Identity roles for fixed SAs `producer` / `mcp-reader` | unconditional (cost ~0) | fixed ns+SA (static association). `producer`: write region trace bucket + `sagemaker-mlflow:*` log actions + read MLflow artifact bucket. `mcp-reader`: read trace bucket + MLflow (search/get) + `sagemaker:CreatePresignedMlflowTrackingServerUrl`. |
| `mcp-gateway-registry` | `mcp_gateway_enabled` (default false) | semi-permanent; state disposable, backends re-register idempotently. |

**(3) Run-project state (`<date>-*/terraform`)** — per-campaign: `profiler-mcp` backend +
gateway registration hook, producer Jobs, campaign namespace. Never flips a base flag.

## 3. Directory placement (question A)

No new top-level module. `infra/bench` = judging + the thin MLflow logging convention + ETL
adapters (Python); `infra/eks` = MCP serving; `infra/data-layer` = buckets + the MLflow App.

```
infra/
├── eks/
│   ├── charts/mcp/                   # gateway (mcp_gateway_enabled); backends in run-projects
│   ├── iam-mcp.tf                    # producer / mcp-reader Pod Identity (fixed SA)
│   └── manifests/mcp-port-forward.sh
├── data-layer/                       # SEPARATE state: trace + mlflow-artifacts buckets, mlflow_app.tf (gated)
└── bench/
    ├── harness/
    │   ├── mlflow_log.py             # NEW: thin convention — required tags/metric names → mlflow.log_*
    │   ├── report.py                 # v2 record shape used as the tag/metric CONVENTION (not a store)
    │   ├── verdict.py                # judge / judge_perf / judge_parity (compute, then log)
    │   ├── perf.py / accelerator.py  # compute perf + GPU/Neuron abstraction (then log)
    │   └── metrics.py                # unchanged accuracy library
    ├── adapters/                     # NEW: ETL adapters (nsys/ncu/DCGM/neuron-profile → tags+metrics+artifact)
    └── contracts/profile-artifact.md # trace S3 layout + finalization + MLflow tag/metric convention
```

## 4. Perf-verification project placement (question B)

Extend `infra/bench` + one dated run-project per campaign (existing three-layer split). Cross-
accelerator analysis is now a **MLflow `search_runs` query** the run-project runs; no bespoke
join store.

## 5. Experiment model on MLflow (question C)

Golden-anchored parity (verified in the real harness code: `metrics.py` compares two
tensors/token-lists, and `reference` is the shared golden): each side computes metrics **vs the
same golden in-region** → one **MLflow run per (experiment, case, accelerator)**. Comparison is
a query over runs sharing `(experiment_id, case_id, golden_hash)` — scalar, no cross-region
tensors. Direct target-vs-target cosine is deferred (a bounded output artifact + a join query).

**Concept → MLflow mapping** (the `report.py` v2 shape becomes this logging *convention*):

| Our concept | MLflow |
|---|---|
| experiment_id | MLflow experiment (name) |
| run_id | **MLflow-assigned run_id** (the shared, stable ID — we stop minting our own) |
| experiment_alias / experiment_note | run tags / run description |
| accelerator, region, instance_type, capacity_type, tenant, golden_hash, case_id, stage | run **tags** (queryable) |
| accuracy metrics (cosine…), perf (latency/throughput), cost | MLflow **metrics** |
| verdict / perf_verdict / accuracy_parity_verdict | run tags (or metrics) |
| profile trace (GB nsys/ncu/ntff) | **OUR S3** URI in a tag `profile_uri` (+ sha256 tag) — NOT an MLflow artifact (200 MB limit, §7) |
| small artifacts (plots, summaries, per-sample parquet) | MLflow artifacts (our artifact bucket) |
| comparison record | a `search_runs` result (optionally re-logged as a summary run) |

`verdict.py` still computes verdicts; `mlflow_log.py` enforces which tags/metrics are mandatory
(the "common experiment-management + ID" layer). ETL adapters (`infra/bench/adapters/`) turn a
given tool's output into that tag/metric/artifact set — the measurer's responsibility, with a
couple of reference adapters (nsys, neuron-profile).

## 6. MCP server (single server, async analysis)

One `profiler-mcp` (tool groups: data / analysis). Data plane reads **MLflow** (`search_runs`,
`get_run`) + returns **presigned URLs** for GB traces in our S3 (`get_presigned_url`; local
Nsight opens them). Analysis (`top_kernels`, `get_roofline`, `suggest_tuning`, `compare_runs`)
runs as **async jobs** (`job_id` → `get_result`), reads only frozen MLflow runs so it works in
any cluster/region. Internal `gpu_adapter`/`neuron_adapter` do chip I/O; tools see normalized
shapes. Gateway nginx: `proxy_buffering off` + raised timeouts; `mcp-port-forward.sh`
auto-reconnects.

## 7. Storage

- **MLflow (managed)** holds the run registry + small artifacts; its artifact store is our S3
  `mlflow-artifacts` bucket. **200 MB download limit** → GB profiler traces are NOT MLflow
  artifacts.
- **GB traces → our `mcp-traces-<region>` bucket** via a crash-safe finalizer: write
  `trace.tmp` on Lustre scratch → fsync + atomic rename + `DONE` marker (sha256) → retried
  `aws s3 cp` → `HeadObject`+sha256 verify → only then log the MLflow run with the `profile_uri`
  tag. A **sweeper CronJob** recovers producer crashes from the shared Lustre PV and quarantines
  (never deletes) failed uploads.
- **Prometheus** = cluster health (existing kube-prometheus-stack). Time-series that matter to
  an experiment are logged as MLflow metrics (per the "lean on MLflow" decision).
- **Region/bucket:** per-region trace buckets (GB stay in region); the MLflow App + artifact
  bucket are central (Tokyo). Comparison reads MLflow (small) — GB traces fetched cross-region
  only for rare deep dives via presigned URL.
- **IAM:** EKS Pod Identity, fixed SAs, bucket-level, from day one (§2.1).

## 8. Observability / experiment slicing

Experiment analysis is **MLflow tags** (`accelerator`, `case_id`, `experiment_id`, `tenant`,
`golden_hash`), sliced by `search_runs`. The three modes:

| Mode | Source |
|---|---|
| GPU-vs-Neuron comparison | `search_runs(experiment, filter accelerator + case_id)` over frozen runs |
| Neuron-only tuning | MLflow runs tagged `accelerator=neuron` (+ live Neuron Prometheus health) |
| GPU-only tuning | MLflow runs tagged `accelerator=gpu` (+ live GPU Prometheus health) |

Prometheus keeps the existing node-pool `tenant` label for live cluster health; no
pod-label→metric plumbing is added (it does not work in kube-prometheus-stack, and experiment
slicing now lives in MLflow anyway — this is *simpler* than the earlier design).

## 9. Local access and UI

- **MLflow UI:** `aws sagemaker create-presigned-mlflow-tracking-server-url --tracking-server-name <app> --session-expiration-duration-in-seconds 1800 --expires-in-seconds 300` → single-use URL in a browser. **No ALB/CloudFront/gateway.**
- **MCP:** one `kubectl port-forward … 8080:80` to the semi-permanent gateway; `profiler-mcp`
  registered by internal DNS; Claude Code registers only the gateway.
- **Nsight has no in-cluster UI** (desktop app) → fetch traces locally via `get_presigned_url`.
- Auth: pods use Pod Identity (SigV4) for MLflow + S3; the human uses their own IAM for the
  presigned URL. Gateway keeps a minimal dev-realm token for MCP only.

## 10. Operational concerns

- **Secrets:** minimal — MLflow uses IAM/SigV4 (no MLflow DB creds to manage; the managed App
  removes that). Gateway token via SSM/External Secrets.
- **Failure:** finalizer-fail → no MLflow run for that side (fail-closed) + sweeper recovery.
- **Self-cost:** serverless MLflow App idles to ~zero; region trace buckets (S3) + Lustre
  throughput are the main costs; MLflow gated off by default.
- **Cleanup:** bucket lifecycle at creation; MLflow App `terraform destroy` when a campaign ends
  (gated); scratch GC by sweeper.

## 11. Phased delivery

| Phase | Content | Exit |
|---|---|---|
| 0 (this) | design + MLflow-App decision; confirm region/bucket + lifecycle; audit `verdict.py` join inputs | this doc + decisions |
| 1 | `infra/data-layer` (buckets + **`aws_sagemaker_mlflow_app`** gated + IAM); `harness/mlflow_log.py` convention; **one manual GPU nsys case → finalizer upload to S3 → MLflow run logged** (verify in MLflow UI via presigned URL); sweeper; CPU-analysis spike | one real GPU run in MLflow with a `profile_uri` to a real S3 trace; presigned UI works |
| 2 | `mcp_gateway_enabled`; `profiler-mcp` data plane (`list_runs`/`get_run`/`get_presigned_url`/`get_metric_timeseries`) reading MLflow | port-forward → Claude Code lists/pulls GPU runs from MLflow |
| 3 | Neuron producer (neuron-profile → MLflow run); analysis tools (async jobs); reference ETL adapters (nsys, neuron-profile) | profile → advice → re-measure → `perf_verdict` loop on one case; both accelerators log to the same MLflow |
| 4 | dated run-project; `compare_runs` via `search_runs`; cross-accelerator report | GPU-vs-Neuron comparison from MLflow |
| 5 (go/no-go) | `cost.py`; direct target-vs-target cosine (output artifact); Nsight Copilot RAG | cost in runs or deferred |

## 12. Open questions

- Region/bucket + lifecycle (recommend per-region trace buckets, central Tokyo MLflow) — confirm.
- `verdict.py` join inputs — golden-anchored → scalar suffices; confirm no per-sample needed initially.
- MLflow App API/Terraform specifics (`aws_sagemaker_mlflow_app` args: name, artifact_store_uri,
  role_arn, model_registration_mode, weekly_maintenance_window_start) — verify presigned-URL API
  name for the *App* vs classic tracking server at implementation.
- Neuron time series into MLflow metrics vs a `neuron-monitor-exporter` — decide in Phase 3.
- Branch: land on its own branch, not `feat/nemotron-parity-bench`.
```

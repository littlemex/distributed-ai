# Design: Phase 1 — MLflow logging convention, trace storage, data layer (detailed)

**Status:** Detailed design (pre-implementation). Builds on `DESIGN-profiling-mcp-platform.md`
(v4, MLflow-centric). Scope = the three foundations most expensive to rework: the **MLflow
logging convention (identity + required tags/metrics)**, the **trace S3 finalization contract**,
and the **data-layer Terraform (buckets + the managed MLflow App)**. Grounded in the actual
`infra/bench` harness code (`report.py`, `verdict.py`, `metrics.py`).

## 1. Parity model — the load-bearing decision (unchanged by the MLflow pivot)

`metrics.py` computes agreement from **two** tensors/token-lists and `reference` = the shared
**golden**. So each side computes metrics **vs the same golden, in-region**, and logs a scalar
**MLflow run**. Cross-accelerator parity = a `search_runs` query over runs sharing
`(experiment_id, case_id, golden_hash)` — no cross-region tensor shipping. Direct
target-vs-target cosine is deferred (a bounded output artifact + a join query).

## 2. MLflow logging convention (replaces the self-built store)

The v2 `report.py` shape is kept **as a convention**, not as a stored JSON. A thin
`harness/mlflow_log.py` maps a computed result to MLflow and **enforces the mandatory identity**
so every run is analyzable later regardless of which tool produced it.

**One MLflow run per (experiment, case, accelerator).** `mlflow_log.py` sets:

- **Experiment:** `experiment_id` → `mlflow.set_experiment(experiment_id)`.
- **Run id:** MLflow-assigned (server-side, stable, globally unique). We stop minting our own
  uuid; `new_run_id()` in `report.py` is dropped as the ID authority.
- **Mandatory tags** (the shared "ID adjudication" surface; missing any → the logger raises):
  `accelerator` (gpu|neuron), `case_id`, `stage`, `golden_hash`, `region`, `instance_type`,
  `capacity_type`, `tenant`, `accuracy_verdict`, `perf_verdict`, and `profile_uri` +
  `profile_sha256` (the S3 pointer to the GB trace). Optional: `experiment_alias`,
  `experiment_note` (also the run description).
- **Metrics:** accuracy (`cosine`, `max_abs_error`, `rel_error_p99`, `token_match_rate`,
  `expert_set_agreement` — whatever `metrics.py` produced) and perf (`latency_p50_ms`,
  `latency_p99_ms`, `tokens_per_s`, `requests_per_s`).
- **Small artifacts** (plots, per-sample parquet, thresholds JSON) → `mlflow.log_artifact`
  (our `mlflow-artifacts` bucket). **GB traces are NOT MLflow artifacts** (200 MB download
  limit) — they live in our region trace bucket and are referenced by the `profile_uri` tag.

`report.py` keeps `hardware_fingerprint`, `make_side`, `environment_fingerprint`,
`build_run_report`/`build_comparison_report` as **the in-memory shape** the logger consumes; it
no longer owns a `write_report`-to-a-canonical-store role. `verdict.py`
(`judge`/`judge_perf`/`judge_parity`), `perf.py`, `accelerator.py`, `metrics.py` are unchanged
(compute, then log). `trend_alert` is superseded by MLflow metric history / `search_runs`
(kept only for offline JSON if ever needed).

## 3. ETL adapters (`infra/bench/adapters/`) — the per-user, per-tool layer

A tool's raw output → the tag/metric/artifact set above. Each adapter is small and independent
(the measurer's responsibility). Phase 1 ships one reference adapter; Neuron in Phase 3.

```
adapters/
├── nsys_adapter.py       # nsys/ncu output → perf metrics + kernel-summary artifact + profile_uri
├── neuron_adapter.py     # (Phase 3) neuron-profile parquet → metrics + profile_uri
└── base.py               # shared: emit(result) → mlflow_log.log_run(...)
```

The contract an adapter must satisfy (so any future tool plugs in): produce a `build_run_report`
dict + a finalized trace object, then call `mlflow_log.log_run(...)`. Nothing else in the
platform depends on the tool.

## 4. `contracts/profile-artifact.md` — layout + finalization + tag convention

### 4.1 S3 layout

```
# GB traces (our bucket, per region) — keyed by the MLflow run id
s3://<acct>-mcp-traces-<region>/exp=<experiment_id>/case=<case_id>/run=<mlflow_run_id>/trace.<ext>
                                                                                        /trace.sha256
# MLflow artifact store (managed by the App; small artifacts only)
s3://<acct>-mlflow-artifacts/...   # MLflow-managed layout
```

The trace key uses the **MLflow run id** so a run in the UI links straight to its trace object
(one-way pointer via the `profile_uri` tag; the object also stores its own sha256).

### 4.2 Trace finalization contract (crash-safe)

`trace.tmp` on Lustre → fsync + atomic rename → `DONE` marker (sha256) → retried `aws s3 cp`
(tar multi-file nsys output into one object) → `HeadObject` + sha256 verify → **only then**
`mlflow_log.log_run(...)` with `profile_uri`/`profile_sha256`. A run never appears in MLflow
pointing at a non-durable trace (fail-closed). A **sweeper CronJob** re-uploads
`DONE`-but-unlogged traces from the shared Lustre PV and quarantines (never deletes) failed
uploads. (MLflow run creation itself is idempotent per producer; a producer that dies before
`log_run` simply has no run, and the sweeper re-drives it.)

### 4.3 Identity / query keys

Runs are found by `search_runs(experiment_id, filter_string="tags.case_id = '…' and
tags.accelerator = 'gpu'")`. A comparison pins two MLflow run ids sharing
`(experiment_id, case_id, golden_hash)`; the join asserts `golden_hash` equality before
comparing (refuses otherwise).

## 5. Data layer (`infra/data-layer`, separate Terraform state)

S3+KMS-backed state, distinct key, so cluster `terraform destroy` never touches it.

- **Buckets:** `mcp-traces-<region>` (per region, GB traces), `mlflow-artifacts` (MLflow's
  artifact store). Versioning on, public blocked, SSE-KMS, `prevent_destroy`; lifecycle set at
  creation (traces → Glacier at N days, expire at M; proposed N=30/M=180, confirm).
- **`aws_sagemaker_mlflow_app`** (gated `mlflow_enabled=false`): `name`, `artifact_store_uri` =
  the `mlflow-artifacts` bucket, `role_arn` = a role the App uses for that bucket,
  `model_registration_mode` (default disabled), `weekly_maintenance_window_start`. Central in
  Tokyo (App region-supported; Melbourne clients log cross-region). Exports `arn` (→ clients'
  `MLFLOW_TRACKING_URI`). Serverless → idle-cost zero.
- **Pod Identity roles (least privilege):**
  - `producer`: PutObject on `mcp-traces-<region>/*`; `sagemaker-mlflow:*` (log runs);
    Get/Put on the MLflow artifact bucket (small artifacts); KMS.
  - `mcp-reader`: GetObject/ListBucket on `mcp-traces-<region>/*`;
    `sagemaker-mlflow:*` read (search/get) + `sagemaker:CreatePresignedMlflowTrackingServerUrl`;
    KMS decrypt.

## 6. Phase 1 producer (minimal, GPU only)

One **manual** GPU case (single nsys capture on a vLLM run in the GPU cluster), the finalizer
(§4.2), the reference `nsys_adapter` (§3), `mlflow_log.log_run` (§2), and the sweeper. Exit:
one real GPU trace in `mcp-traces-<region>` and **one MLflow run** with `profile_uri` pointing
at it, viewable in the MLflow UI via a presigned URL. CPU-analysis feasibility spike answered.

## 7. Decisions taken here

- Backbone = **serverless MLflow App** via `aws_sagemaker_mlflow_app` (Terraform-native +
  idle-cost zero + gated). Run IDs are MLflow-assigned (we stop minting uuids).
- Region/bucket: per-region trace buckets + central Tokyo MLflow; comparison via `search_runs`.
- Parity: golden-anchored → scalar runs suffice; per-sample deferred.
- 200 MB MLflow limit → GB traces in our S3, referenced by tag.

## 8. Deferred / open

- Direct target-vs-target output cosine via an output artifact (bounded eval subset).
- Lifecycle day counts (N=30/M=180) — confirm.
- Exact `aws_sagemaker_mlflow_app` presigned-URL API name for the App vs classic tracking
  server — verify at implementation.
- `judge_perf`/`judge_parity` threshold derivation (noise-floor method).

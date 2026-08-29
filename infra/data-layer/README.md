# data-layer — durable record of the cross-accelerator profiling platform

Separate Terraform state holding the platform's **record of record**: the S3 buckets that store
profiler artifacts, the managed MLflow App that indexes runs, and the least-privilege IAM roles
the clusters assume via EKS Pod Identity. It is deliberately a *separate* state from `infra/eks`
so that tearing down a cluster can never delete experiment data or run history.

## What it creates

| Resource | Notes |
|---|---|
| Per-region trace buckets (`var.trace_regions`) | GB profiler artifacts (`.nsys-rep`, `.ncu-rep`, `.neff`/`.ntff`, …) stay in the Region they were captured in. Versioned, KMS-encrypted, lifecycle to Glacier IR then expiry. |
| `mlflow-artifacts` bucket | MLflow's own artifact store (small artifacts only; GB traces live in the trace buckets and are referenced by tag). |
| KMS CMK | Encrypts traces + artifacts. |
| `aws_sagemaker_mlflow_app` (**gated**, `mlflow_enabled=false`) | The managed serverless MLflow App — the clients' `MLFLOW_TRACKING_URI`. Paid resource, so opt-in per campaign; serverless idle cost is ~zero. One central App both clusters log to over SigV4. |
| IAM roles `producer`, `mcp-reader` | Mapped to fixed EKS service accounts via Pod Identity. `producer` writes traces + logs MLflow runs (no `Delete*`). `mcp-reader` reads traces + MLflow. Both are scoped to the ARN of the MLflow this layer creates, or to `var.mlflow_tracking_server_arn` for one it did not. On the `app` backend the reader can also delete from MLflow, because an app exposes one action covering its whole API; the `janitor` therefore gets no MLflow access at all there. |

## Contract with the other modules

- `infra/eks` associates its fixed service accounts to `producer_role_arn` / `mcp_reader_role_arn`
  (outputs here) via Pod Identity — it never creates these roles.
- The Python platform library (`infra/bench/experiment_store`) reads `trace_buckets`,
  `mlflow_artifacts_bucket`, and `mlflow_arn` (outputs here) as its configuration.

## Usage

```bash
cd infra/data-layer
terraform init            # uses an S3+KMS backend in real use; see versions.tf
terraform apply           # buckets + IAM only (the MLflow stays OFF by default)

# opt in to a managed SageMaker MLflow for a campaign. Which one is not optional: "app" is
# serverless, "server" is a tracking server billed for every hour it is running. Switching later
# destroys the one that exists along with every run's metadata, so this stops if it is unset.
terraform apply -var mlflow_enabled=true -var mlflow_backend=app
terraform output -raw mlflow_arn            # -> MLFLOW_TRACKING_URI for producers/readers
terraform output -raw mlflow_ui_url         # -> where a human reads the recordings
terraform output -json trace_buckets
```

The MLflow IAM needs no second pass: the policies are scoped to the ARN of the MLflow this layer
creates, and a layer with no MLflow carries no MLflow statement rather than a wildcard. Point them at a
tracking server this layer did not create with `-var mlflow_tracking_server_arn=...`, which requires
`mlflow_backend=server` because only that backend's actions can address one.

Buckets carry `prevent_destroy`; a `terraform destroy` will not silently delete the record of
record. The MLflow can be destroyed (gated) when a campaign ends.

## UI access

The MLflow UI opens through a SageMaker presigned URL — there is no ALB/CloudFront. The command differs
per backend, which is why `mlflow_ui_url` exists for the plain link:

```bash
# app (serverless)
aws sagemaker create-presigned-mlflow-app-url --arn "$(terraform output -raw mlflow_arn)" \
  --session-expiration-duration-in-seconds 1800 --expires-in-seconds 300

# server (tracking server)
aws sagemaker create-presigned-mlflow-tracking-server-url \
  --tracking-server-name "$(terraform output -raw mlflow_name)" \
  --session-expiration-duration-in-seconds 1800 --expires-in-seconds 300
```

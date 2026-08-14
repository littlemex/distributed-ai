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
| IAM roles `producer`, `mcp-reader` | Mapped to fixed EKS service accounts via Pod Identity. `producer` writes traces + logs MLflow runs (no `Delete*`). `mcp-reader` reads traces + MLflow. Scoped to `var.mlflow_app_arn` when set. |

## Contract with the other modules

- `infra/eks` associates its fixed service accounts to `producer_role_arn` / `mcp_reader_role_arn`
  (outputs here) via Pod Identity — it never creates these roles.
- The Python platform library (`infra/bench/experiment_store`) reads `trace_buckets`,
  `mlflow_artifacts_bucket`, and `mlflow_app_arn` (outputs here) as its configuration.

## Usage

```bash
cd infra/data-layer
terraform init            # uses an S3+KMS backend in real use; see versions.tf
terraform apply           # buckets + IAM only (MLflow App stays OFF by default)

# opt in to the managed MLflow App for a campaign:
terraform apply -var mlflow_enabled=true
terraform output -raw mlflow_app_arn        # -> MLFLOW_TRACKING_URI for producers/readers
terraform output -json trace_buckets

# tighten MLflow IAM from wildcard to the created App once its ARN is known:
terraform apply -var mlflow_enabled=true -var mlflow_app_arn="$(terraform output -raw mlflow_app_arn)"
```

Buckets carry `prevent_destroy`; a `terraform destroy` will not silently delete the record of
record. The MLflow App can be destroyed (gated) when a campaign ends.

## UI access

The MLflow UI opens through a SageMaker presigned URL — there is no ALB/CloudFront:

```bash
aws sagemaker create-presigned-mlflow-app-url --arn "$(terraform output -raw mlflow_app_arn)" \
  --session-expiration-duration-in-seconds 1800 --expires-in-seconds 300
```

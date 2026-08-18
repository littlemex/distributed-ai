variable "region" {
  description = "Region for this data-layer state, the MLflow App, and the artifact bucket (central; e.g. Tokyo)."
  type        = string
  default     = "ap-northeast-1"
}

variable "name_prefix" {
  description = "Prefix for bucket and resource names. Account id is appended for global S3 uniqueness."
  type        = string
  default     = "mcp"
}

variable "trace_regions" {
  description = "Regions that get a per-region GB-trace bucket (traces stay in-region; only small reports/MLflow data are central)."
  type        = list(string)
  default     = ["ap-northeast-1", "ap-southeast-4"] # GPU (Tokyo), Neuron (Melbourne)
}

variable "trace_glacier_after_days" {
  description = "Transition GB traces to Glacier Instant Retrieval after N days (0 = never)."
  type        = number
  default     = 30
}

variable "trace_expire_after_days" {
  description = "Expire GB traces after M days (0 = never). Must exceed trace_glacier_after_days when both set."
  type        = number
  default     = 180
}

variable "mlflow_enabled" {
  description = "Create the managed SageMaker MLflow tracking server. Paid and always-on while created, so default OFF. Setting this false and applying DESTROYS the server and its run metadata (only the S3 artifacts survive) — that is a teardown, not a pause. To pause cost while idle, use `aws sagemaker stop-mlflow-tracking-server` instead."
  type        = bool
  default     = false
}

variable "mlflow_app_name" {
  description = "Name of the SageMaker MLflow tracking server (when mlflow_enabled)."
  type        = string
  default     = "mcp-profiling"
}

variable "mlflow_tracking_server_size" {
  description = "SageMaker MLflow tracking server size: Small, Medium, or Large."
  type        = string
  default     = "Small"
  validation {
    condition     = contains(["Small", "Medium", "Large"], var.mlflow_tracking_server_size)
    error_message = "mlflow_tracking_server_size must be one of Small, Medium, or Large."
  }
}

variable "mlflow_version" {
  description = "MLflow version for the tracking server. Pinned for reproducibility: changing it forces a replacement (which loses run metadata), so keep it stable across applies."
  type        = string
  default     = "3.0"
}

variable "mlflow_app_arn" {
  description = "MLflow tracking server ARN to scope producer/reader MLflow IAM to. Empty = wildcard (single-account dev). Set to aws_sagemaker_mlflow_tracking_server.this[0].arn to remove the wildcard. Must be an mlflow-tracking-server ARN: the sagemaker-mlflow:* actions do not authorize an mlflow-app ARN."
  type        = string
  default     = ""
  validation {
    condition     = var.mlflow_app_arn == "" || !can(regex(":mlflow-app/", var.mlflow_app_arn))
    error_message = "mlflow_app_arn must be an mlflow-tracking-server ARN, not a serverless mlflow-app ARN (the latter does not authorize sagemaker-mlflow:* actions)."
  }
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = { project = "profiling-mcp-platform", managed_by = "terraform" }
}

# Guardrail: with both set, expiry must be after the Glacier transition, else the lifecycle rule
# is contradictory. Fails at plan time rather than silently mis-tiering.
resource "terraform_data" "lifecycle_guard" {
  lifecycle {
    precondition {
      condition     = var.trace_expire_after_days == 0 || var.trace_glacier_after_days == 0 || var.trace_expire_after_days > var.trace_glacier_after_days
      error_message = "trace_expire_after_days must be greater than trace_glacier_after_days when both are set."
    }
  }
}

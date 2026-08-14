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
  description = "Create the managed SageMaker MLflow App. It is a paid resource, so default OFF — opt-in per campaign."
  type        = bool
  default     = false
}

variable "mlflow_app_name" {
  description = "Name of the SageMaker MLflow App (when mlflow_enabled)."
  type        = string
  default     = "mcp-profiling"
}

variable "mlflow_app_arn" {
  description = "MLflow App ARN to scope producer/reader MLflow IAM to. Empty = wildcard (single-account dev). Set to aws_sagemaker_mlflow_app.this[0].arn once known to remove the wildcard."
  type        = string
  default     = ""
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

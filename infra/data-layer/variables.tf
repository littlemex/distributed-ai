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
  description = "Create the SageMaker MLflow this data layer records to (which one is var.mlflow_backend). Paid, so default OFF. Setting this false and applying DESTROYS it and its run metadata (only the S3 artifacts survive) — that is a teardown, not a pause. A tracking server can be paused instead with `aws sagemaker stop-mlflow-tracking-server`; an app has nothing to stop (the API has no start/stop for one)."
  type        = bool
  default     = false
}

variable "mlflow_name" {
  description = <<-EOT
    Name of the SageMaker MLflow this data layer records to. Empty derives it from name_prefix, which
    is what keeps two data layers in one account and region from colliding: every other resource here
    is already named after the prefix, and a fixed default made the MLflow the one name a second data
    layer could not have. Changing it after the fact REPLACES the MLflow, destroying its run metadata.
  EOT
  type        = string
  default     = ""
}

variable "mlflow_backend" {
  description = <<-EOT
    Which SageMaker MLflow to create: "app" (serverless) or "server" (a managed tracking server,
    billed for every hour it is running and stoppable to pause that). Both speak the same MLflow REST API
    and both are addressed by their ARN as MLFLOW_TRACKING_URI, so nothing above this layer changes;
    the sagemaker-mlflow plugin reads the resource type out of the ARN to pick the endpoint and the
    signing service.

    THIS IS THE ONE DECISION THAT CANNOT BE REVISITED. Changing it on a live data layer destroys the
    MLflow that exists along with every run's metadata (the S3 artifacts survive, but not what
    experiment they belonged to). There is deliberately no usable default for that reason: creating an
    MLflow requires saying which one, enforced by a precondition in mlflow.tf, so a bare
    `terraform apply` that forgot the flag stops instead of deciding. To change backends, create a new
    data layer.

    What else differs is how tightly a caller can be scoped. A tracking server exposes granular
    sagemaker-mlflow:* actions, so a policy can allow logging while forbidding deletion. An app
    exposes exactly one action, sagemaker:CallMlflowAppApi, covering its whole REST API — so on "app"
    every role that can read MLflow can also delete from it. The analysis reader needs that access to
    resolve a run, and accepts it; the janitor does not get it at all, because a delete-capable
    garbage collector holding delete on unrecoverable metadata is the one combination worth refusing
    (it degrades to keeping every trace prefix — see iam.tf).
  EOT
  type        = string
  default     = ""

  validation {
    condition     = contains(["app", "server", ""], var.mlflow_backend)
    error_message = "mlflow_backend must be \"app\" or \"server\" (or \"\" when mlflow_enabled is false, since then neither is created)."
  }
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

variable "mlflow_tracking_server_arn" {
  description = <<-EOT
    An EXTERNAL mlflow-tracking-server ARN to scope the MLflow IAM to, for the case where the records
    live on a tracking server this layer did not create. Leave empty otherwise: the policies are then
    scoped to the MLflow this layer does create, whose ARN it knows. Nothing is ever scoped to a
    wildcard — a policy with no MLflow to name simply carries no MLflow statement.
  EOT
  type        = string
  default     = ""
  validation {
    condition     = var.mlflow_tracking_server_arn == "" || !can(regex(":mlflow-app/", var.mlflow_tracking_server_arn))
    error_message = "mlflow_tracking_server_arn scopes the sagemaker-mlflow:* actions, which only a tracking server exposes. An app is addressed by sagemaker:CallMlflowAppApi on its own ARN, which this layer only knows for an app it created itself."
  }
}

# REMOVED, both kept only to fail loudly. A stale name in a .tfvars file is a warning, not an error
# (measured: -var on an undeclared variable errors, a .tfvars entry only warns), so without these
# declarations an upgrade would take the old value, ignore it, and carry on with the default.
#
# What that costs differs per variable, and neither is something to find out from a plan nobody read.
variable "mlflow_app_arn" {
  description = "REMOVED: renamed to mlflow_tracking_server_arn, because it never named an app. Setting it stops the run."
  type        = string
  default     = ""
  validation {
    condition     = var.mlflow_app_arn == ""
    error_message = "mlflow_app_arn was renamed to mlflow_tracking_server_arn (it scopes an external tracking server, and never named an app). Pass the new name."
  }
}

# Ignoring this one is the worse of the two: the name would fall back to the derived default, and
# renaming an MLflow REPLACES it, so an upgrade that merely kept an old .tfvars would destroy every
# run's metadata on a tracking server that had any other name.
variable "mlflow_app_name" {
  description = "REMOVED: renamed to mlflow_name, because it names either backend. Setting it stops the run."
  type        = string
  default     = ""
  validation {
    condition     = var.mlflow_app_name == ""
    error_message = "mlflow_app_name was renamed to mlflow_name (it names whichever MLflow this data layer records to). Pass the new name — ignoring it would re-derive the name, and renaming an MLflow destroys its run metadata."
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

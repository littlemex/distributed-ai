# The SageMaker MLflow behind the platform's record of record — the experiment-management backbone.
# GATED: paid resource, default OFF (var.mlflow_enabled).
#
# Two shapes of the same thing, chosen with var.mlflow_backend, whose description is where the
# trade-off between them is written down. In short: "app" is serverless and has nothing to stop;
# "server" is billed for every hour it is running and can be stopped to pause that, and it is the only one
# whose IAM can say "log but never delete". mlflow_version is pinned because changing it forces a
# replacement of a tracking server.
#
# Everything above this layer reads one ARN and one URL (the locals at the bottom) and never asks
# which backend produced them.

# Creating an MLflow requires saying which one. Left to a default, a `terraform apply` that forgot the
# flag would decide it, and deciding wrong destroys the MLflow that holds the run metadata — so this
# stops instead. Nothing is created when mlflow_enabled is false, so the backend may be unset there.
resource "terraform_data" "mlflow_backend_is_chosen" {
  input = var.mlflow_backend

  lifecycle {
    precondition {
      condition     = !var.mlflow_enabled || contains(["app", "server"], var.mlflow_backend)
      error_message = "mlflow_enabled is true but mlflow_backend is unset. Pass app (serverless) or server (a managed tracking server). If this data layer already has one, pass the one it already has: switching destroys the MLflow that exists along with every run's metadata."
    }
    # An external tracking server is only addressable on the backend whose actions can address it. Left
    # unchecked, the pairing produces a policy that allows the app's one action against a tracking
    # server ARN — valid HCL, valid IAM, and 403 on every data-plane call.
    precondition {
      condition     = var.mlflow_tracking_server_arn == "" || var.mlflow_backend == "server"
      error_message = "mlflow_tracking_server_arn names a tracking server, which only the \"server\" backend authorizes. Set mlflow_backend to server, or leave the ARN empty to scope the policies to the MLflow this layer creates."
    }
  }
}

resource "aws_sagemaker_mlflow_app" "this" {
  count = var.mlflow_enabled && var.mlflow_backend == "app" ? 1 : 0

  name               = local.mlflow_name
  artifact_store_uri = "s3://${aws_s3_bucket.mlflow_artifacts.bucket}/mlflow"
  role_arn           = aws_iam_role.mlflow_app.arn

  tags = var.tags
}

resource "aws_sagemaker_mlflow_tracking_server" "this" {
  count = var.mlflow_enabled && var.mlflow_backend == "server" ? 1 : 0

  tracking_server_name         = local.mlflow_name
  artifact_store_uri           = "s3://${aws_s3_bucket.mlflow_artifacts.bucket}/mlflow"
  role_arn                     = aws_iam_role.mlflow_app.arn
  tracking_server_size         = var.mlflow_tracking_server_size
  mlflow_version               = var.mlflow_version
  automatic_model_registration = false

  tags = var.tags
}

locals {
  # One name for whichever backend is created, so the naming rule exists once. The installer looks a
  # live MLflow up by this name when the state has lost it, and reads it back from the mlflow_name
  # output rather than re-deriving it, so that changing the rule here cannot make that search miss.
  mlflow_name = var.mlflow_name != "" ? var.mlflow_name : "${var.name_prefix}-mlflow"

  # One address for whichever exists, so that every caller above this layer — the installer, the
  # ConfigMap it publishes, the recorder, the analysis MCP — keeps reading a single value.
  mlflow_arn = var.mlflow_backend == "app" ? try(aws_sagemaker_mlflow_app.this[0].arn, "") : try(aws_sagemaker_mlflow_tracking_server.this[0].arn, "")

  # Where a human opens the recordings. The two backends are served from different hosts, and an app's
  # host carries its id, so the URL is derived here — next to the resources that define it — rather
  # than reassembled from an ARN by every reader. Measured against a live app on 2026-08-28:
  # create-presigned-mlflow-app-url returns https://<app-id>.mlflow.sagemaker.<region>.app.aws/...
  mlflow_ui_url = local.mlflow_arn == "" ? "" : (
    var.mlflow_backend == "app"
    ? "https://${try(split("/", local.mlflow_arn)[1], "")}.mlflow.sagemaker.${var.region}.app.aws/"
    : "https://${var.region}.experiments.sagemaker.aws/"
  )
}

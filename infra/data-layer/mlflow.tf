# Managed SageMaker MLflow tracking server — the experiment-management backbone.
# GATED: paid resource, default OFF (var.mlflow_enabled). One central tracking server (this
# region) that GPU and Neuron clusters log to over SigV4; the UI opens via a presigned URL
# (no ALB). Its ARN is the clients' MLFLOW_TRACKING_URI.
#
# Tracking server (NOT the serverless "MLflow App"): its data-plane REST is authorized by the
# granular sagemaker-mlflow:* actions on the mlflow-tracking-server resource type, so the scoped
# producer/reader roles below can reach it. The serverless MLflow App resource type does NOT
# authorize those scoped actions (only a principal with account-wide access can call its data
# plane), which is why least-privilege pods cannot log to it. The trade-off is that a tracking
# server is always-on billed. To pause cost while idle use `aws sagemaker
# stop-mlflow-tracking-server` (state is preserved); do NOT flip var.mlflow_enabled to false for
# that — count=0 DESTROYS the server and its run metadata (only the S3 artifacts survive), which
# is a teardown, not a pause. mlflow_version is pinned because changing it forces a replacement.

resource "aws_sagemaker_mlflow_tracking_server" "this" {
  count = var.mlflow_enabled ? 1 : 0

  tracking_server_name         = var.mlflow_app_name != "" ? var.mlflow_app_name : "${var.name_prefix}-mlflow"
  artifact_store_uri           = "s3://${aws_s3_bucket.mlflow_artifacts.bucket}/mlflow"
  role_arn                     = aws_iam_role.mlflow_app.arn
  tracking_server_size         = var.mlflow_tracking_server_size
  mlflow_version               = var.mlflow_version
  automatic_model_registration = false

  tags = var.tags
}

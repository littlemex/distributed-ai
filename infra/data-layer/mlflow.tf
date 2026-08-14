# Managed SageMaker serverless MLflow App — the experiment-management backbone.
# GATED: paid resource, default OFF (var.mlflow_enabled). Serverless => idle cost ~zero. One
# central App (this region, e.g. Tokyo) that GPU and Neuron clusters log to over SigV4; the UI
# opens via a presigned URL (no ALB). Its ARN is the clients' MLFLOW_TRACKING_URI.

resource "aws_sagemaker_mlflow_app" "this" {
  count = var.mlflow_enabled ? 1 : 0

  name               = var.mlflow_app_name
  artifact_store_uri = "s3://${aws_s3_bucket.mlflow_artifacts.bucket}/mlflow"
  role_arn           = aws_iam_role.mlflow_app.arn

  tags = var.tags
}

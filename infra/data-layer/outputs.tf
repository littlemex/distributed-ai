output "trace_buckets" {
  description = "Per-region GB-trace bucket names (producers write finalized traces here)."
  value       = { for r, b in aws_s3_bucket.traces : r => b.bucket }
}

output "mlflow_artifacts_bucket" {
  description = "MLflow artifact store bucket (small artifacts only)."
  value       = aws_s3_bucket.mlflow_artifacts.bucket
}

output "kms_key_arn" {
  value       = aws_kms_key.data.arn
  description = "CMK used for trace + artifact encryption."
}

output "producer_role_arn" {
  value       = aws_iam_role.producer.arn
  description = "IAM role mapped to the EKS `producer` service account via Pod Identity."
}

output "mcp_reader_role_arn" {
  value       = aws_iam_role.mcp_reader.arn
  description = "IAM role mapped to the EKS `mcp-reader` service account via Pod Identity."
}

output "mlflow_app_arn" {
  description = "MLflow App ARN (MLFLOW_TRACKING_URI for clients). Empty when mlflow_enabled=false."
  value       = try(aws_sagemaker_mlflow_app.this[0].arn, "")
}

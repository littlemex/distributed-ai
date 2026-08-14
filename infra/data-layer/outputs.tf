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

output "s3files_file_system_id" {
  description = "S3 Files file system id over the trace bucket (empty when s3files_enabled=false)."
  value       = var.s3files_enabled ? jsondecode(aws_cloudcontrolapi_resource.s3files_fs[0].properties).FileSystemId : ""
}

output "s3files_access_point_id" {
  description = "S3 Files access point id (empty when disabled)."
  value       = var.s3files_enabled ? jsondecode(aws_cloudcontrolapi_resource.s3files_ap[0].properties).AccessPointId : ""
}

output "s3files_volume_handle" {
  description = "The EFS-CSI PV volumeHandle for the S3 Files fs: \"s3files:<fs>::<ap>\" (empty when disabled). Feed to charts/analysis-mcp --set s3files.volumeHandle. A bare fs-id does NOT work."
  value = var.s3files_enabled ? format("s3files:%s::%s",
    jsondecode(aws_cloudcontrolapi_resource.s3files_fs[0].properties).FileSystemId,
    jsondecode(aws_cloudcontrolapi_resource.s3files_ap[0].properties).AccessPointId) : ""
}

output "s3files_role_arn" {
  description = "IAM role S3 Files assumes to sync the bucket (empty when disabled)."
  value       = var.s3files_enabled ? aws_iam_role.s3files[0].arn : ""
}

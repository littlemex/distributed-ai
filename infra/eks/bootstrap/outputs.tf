output "bucket" {
  description = "Name of the S3 bucket that stores the Terraform state."
  value       = aws_s3_bucket.state.bucket
}

output "dynamodb_table" {
  description = "Name of the DynamoDB table used for Terraform state locking."
  value       = aws_dynamodb_table.lock.name
}

output "backend_hcl" {
  description = "Ready-to-paste backend.hcl contents for the parent infra/eks module."
  value       = local.backend_hcl
}

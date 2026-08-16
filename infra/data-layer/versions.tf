# Data layer for the profiling/experiment platform: durable buckets + the managed MLflow App.
# SEPARATE Terraform state from infra/eks so a cluster `terraform destroy` never touches the
# record of record (the buckets are prevent_destroy). Use an S3 + KMS remote backend with a
# distinct state key, mirroring infra/eks (configured at init via -backend-config; not hardcoded
# here so the module stays environment-independent).

terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # aws_sagemaker_mlflow_app is a recent resource; pin a version that includes it.
      version = ">= 5.80.0"
    }
  }

  # backend "s3" {}   # supply bucket/key/region/kms via `terraform init -backend-config=...`
}

provider "aws" {
  region = var.region
}

################################################################################
# Provider configuration for THIS root module's own resources (the ComfyUI ECR
# repository + IAM in comfyui-image-builder.tf).
#
# The cluster module (module.cluster) configures its OWN aws/helm/kubectl
# providers internally from the region/profile we pass it — we do not, and cannot,
# pass configured providers down to it (it declares its own `provider` blocks).
# So the only provider this root needs to configure is a plain `aws` for the ECR
# repo and IAM role/policy, pointed at the same region + profile as the cluster.
################################################################################

provider "aws" {
  region  = var.region
  profile = var.aws_profile
}

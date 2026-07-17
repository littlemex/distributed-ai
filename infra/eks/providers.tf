################################################################################
# Provider configuration
#
# Two AWS provider instances:
#   default     — deploys all resources in var.region (us-east-2)
#   aws.us_east_1 — used only for ECR Public auth token (ECR Public API is
#                   global but requires requests to us-east-1)
#                   Referenced by: karpenter.tf data.aws_ecrpublic_authorization_token
################################################################################

provider "aws" {
  region  = var.region
  profile = var.aws_profile
}

provider "aws" {
  alias   = "us_east_1"
  region  = "us-east-1"
  profile = var.aws_profile
}

locals {
  # aws eks get-token args, common to the helm and kubectl providers. --profile is
  # only appended when var.aws_profile is set, so users on env-var/instance-role/SSO
  # credentials (no named profile) authenticate the same way the AWS provider does.
  eks_get_token_args = concat(
    ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region],
    var.aws_profile != null ? ["--profile", var.aws_profile] : []
  )
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = local.eks_get_token_args
    }
  }
}

provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = local.eks_get_token_args
  }
}

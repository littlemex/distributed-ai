################################################################################
# Provider requirements — kept in lockstep with ../../infra/eks/versions.tf.
#
# This is a THIN root module: beyond a ComfyUI-specific ECR repository + IAM
# (comfyui-image-builder.tf) it declares no resources of its own. Everything else
# is the reusable cluster module, referenced as `module "cluster"` in main.tf.
# The provider set below must be a superset of what that child module needs: a
# child module inherits its provider PLUGINS from the root's required_providers,
# while declaring the provider CONFIGURATIONS itself (see the base module's
# providers.tf). We re-declare the same set here so this root can also configure
# the aws provider for its own ECR/IAM resources.
################################################################################

terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.70"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.15"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14"
    }
    http = {
      source  = "hashicorp/http"
      version = ">= 3.4"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0"
    }
  }

  # ── State isolation (the whole reason this is a separate root module) ─────────
  # The base infra/eks state (us-east-2 / distai-eks-smoke) lives in its own
  # working directory and is NEVER touched from here: this root has its OWN state
  # file. LOCAL by default (matches the base module today) so a first apply needs
  # no bootstrap. For anything longer-lived than a smoke test, uncomment the S3
  # backend below and run `terraform init -migrate-state` — an env-per-key layout
  # means two clusters can never collide. Terraform 1.10+ supports S3 native
  # locking (use_lockfile), so no DynamoDB table is required.
  #
  # backend "s3" {
  #   bucket       = "<your-tf-state-bucket>"
  #   key          = "comfyui-minimax-h3/us-west-2/terraform.tfstate"
  #   region       = "us-west-2"
  #   encrypt      = true
  #   use_lockfile = true
  # }
}

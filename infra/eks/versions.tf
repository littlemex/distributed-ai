terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.52, < 7.0" # terraform-aws-eks v21 requires aws >= 6.52
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.15"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.9" # latest: 1.9.4; ~>1.18 would resolve to nothing (no 1.18.x exists)
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "~> 2.3"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4" # data.http in alb-controller.tf (fetches the AWS LB Controller IAM policy)
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

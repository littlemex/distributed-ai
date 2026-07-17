################################################################################
# AWS Load Balancer Controller
#
# Gated by var.enable_demo_app (default false). This module's base cluster
# (no accelerator pools, no demo app) should never stand up a public ALB.
#
# Helm chart: aws-load-balancer-controller (repo: https://aws.github.io/eks-charts)
# Chart version: var.alb_controller_chart_version (default 3.4.1)
# App/release version (IAM policy fetch only): var.alb_controller_app_version —
# a SEPARATE variable because chart and app versions are independent series
# (see that variable's description).
#
# Auth: EKS Pod Identity (same pattern as ebs-csi and Karpenter in iam.tf)
#   IAM role ← official iam_policy.json fetched from upstream GitHub tag
#   Pod Identity association: kube-system / aws-load-balancer-controller SA
#
# Ordering note: helm creates the SA (serviceAccount.create=true), and the Pod
# Identity association binds to that SA name. The association can be created
# before the SA exists; EKS resolves it at pod startup.
#
# Multi-cluster note: the official policy uses `elbv2.k8s.aws/cluster` resource
# tags for most mutating actions, so it is safe in multi-cluster accounts.
# For tighter isolation, add a permissions boundary or `aws:ResourceTag` condition
# scoped to this cluster's name.
################################################################################

locals {
  demo_app_enabled = var.enable_demo_app ? 1 : 0
}

# ── IAM policy (official upstream JSON, pinned to chart app version) ─────────
# lifecycle postcondition verifies the fetch succeeded before the policy is
# created, catching GitHub outages or tag typos at plan time.

data "http" "alb_iam_policy" {
  count = local.demo_app_enabled
  url   = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v${var.alb_controller_app_version}/docs/install/iam_policy.json"

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "Failed to fetch ALB controller IAM policy (HTTP ${self.status_code}). Check var.alb_controller_app_version (a release tag, not the chart version): v${var.alb_controller_app_version}"
    }
  }
}

resource "aws_iam_policy" "alb_controller" {
  count       = local.demo_app_enabled
  name        = "${var.cluster_name}-alb-controller"
  description = "AWS Load Balancer Controller policy for ${var.cluster_name}"
  policy      = data.http.alb_iam_policy[0].response_body
  tags        = var.tags
}

# ── IAM role (Pod Identity trust policy) ─────────────────────────────────────

data "aws_iam_policy_document" "alb_controller_assume" {
  count = local.demo_app_enabled
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "alb_controller" {
  count              = local.demo_app_enabled
  name               = "${var.cluster_name}-alb-controller"
  assume_role_policy = data.aws_iam_policy_document.alb_controller_assume[0].json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  count      = local.demo_app_enabled
  role       = aws_iam_role.alb_controller[0].name
  policy_arn = aws_iam_policy.alb_controller[0].arn
}

# ── Pod Identity association ──────────────────────────────────────────────────
# Binds the IAM role to the SA that helm creates (serviceAccount.name below).

resource "aws_eks_pod_identity_association" "alb_controller" {
  count           = local.demo_app_enabled
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.alb_controller[0].arn
  tags            = var.tags
}

# ── Helm release ──────────────────────────────────────────────────────────────
# helm provider ~> 2.15 is pinned in versions.tf; set{} syntax is v2-compatible.
# When upgrading to helm provider v3, migrate set{} blocks to a values map.

resource "helm_release" "alb_controller" {
  count            = local.demo_app_enabled
  name             = "aws-load-balancer-controller"
  repository       = "https://aws.github.io/eks-charts"
  chart            = "aws-load-balancer-controller"
  version          = var.alb_controller_chart_version
  namespace        = "kube-system"
  create_namespace = false # kube-system already exists
  wait             = true
  timeout          = 300

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "region"
    value = var.region
  }

  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }

  # SA created by helm; name must match Pod Identity association above
  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  # Run on stable system nodes (same pattern as Karpenter)
  # type = "string" forces Helm to treat "true" as a string, not a bool.
  # Without this, PodSpec.nodeSelector unmarshals bool → error.
  set {
    name  = "nodeSelector.karpenter\\.sh/controller"
    value = "true"
    type  = "string"
  }

  depends_on = [
    module.eks,
    aws_iam_role_policy_attachment.alb_controller,
    aws_eks_pod_identity_association.alb_controller,
  ]
}

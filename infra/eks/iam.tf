################################################################################
# IAM for Karpenter — via terraform-aws-modules/eks/aws//modules/karpenter
#
# outputs.tf (adjacent team) expects:
#   module.karpenter.iam_role_arn          → Karpenter controller role
#   module.karpenter.node_iam_role_arn     → Karpenter node role
#   module.karpenter.instance_profile_name → EC2 instance profile
#
# The karpenter sub-module (v21.24.0) creates:
#   - KarpenterController IAM role (Pod Identity, not IRSA)
#   - Pod Identity association (kube-system/karpenter SA)
#   - KarpenterNode IAM role + instance profile
#   - Access entry so nodes can join the cluster
#   - SQS interruption queue + EventBridge rules
#
# Additional node policies attached here:
#   - S3 read/write  (experiment data)
#   - ECR read-only  (already included in AmazonEC2ContainerRegistryReadOnly
#                     via node_iam_role_attach_cni_policy=true + explicit attachment)
################################################################################

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "21.24.0"

  cluster_name = module.eks.cluster_name

  # Pod Identity association: kube-system/karpenter SA → controller role
  create_pod_identity_association = true
  namespace                       = local.karpenter_namespace
  service_account                 = local.karpenter_service_account

  # Deterministic node role name so EC2NodeClass.spec.instanceProfile is predictable
  node_iam_role_use_name_prefix = false
  node_iam_role_name            = local.karpenter_node_role_name

  # Create EC2 instance profile (required by EC2NodeClass.spec.instanceProfile)
  create_instance_profile = true

  # Enable SQS-based interruption queue (spot termination / rebalance / health)
  enable_spot_termination = true

  # Additional policies on the Karpenter node role
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    NodeS3ReadWrite              = aws_iam_policy.karpenter_node_s3.arn
  }

  tags = var.tags

  depends_on = [module.eks]
}

################################################################################
# S3 read/write policy for Karpenter-provisioned nodes
# Grants access to account-scoped experiment data buckets.
################################################################################

data "aws_partition" "current" {}

data "aws_iam_policy_document" "karpenter_node_s3" {
  statement {
    sid    = "S3ReadWrite"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    # Scoped to buckets that include the account ID in the name (convention used in this project)
    resources = [
      "arn:${data.aws_partition.current.partition}:s3:::${var.aws_account_id}-*",
      "arn:${data.aws_partition.current.partition}:s3:::${var.aws_account_id}-*/*",
    ]
  }
}

resource "aws_iam_policy" "karpenter_node_s3" {
  name        = "${var.cluster_name}-karpenter-node-s3"
  description = "S3 read/write for Karpenter-provisioned GPU nodes (${var.cluster_name})"
  policy      = data.aws_iam_policy_document.karpenter_node_s3.json
  tags        = var.tags
}

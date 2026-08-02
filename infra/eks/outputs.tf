# ── EKS cluster ──────────────────────────────────────────────────────────────

output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "API server endpoint of the EKS cluster."
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded certificate authority data for the cluster."
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "cluster_oidc_issuer_url" {
  description = "OIDC issuer URL used for IRSA."
  value       = module.eks.cluster_oidc_issuer_url
}

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider associated with the cluster."
  value       = module.eks.oidc_provider_arn
}

output "cluster_primary_security_group_id" {
  description = "Security group ID attached to the EKS control plane ENIs."
  value       = module.eks.cluster_primary_security_group_id
}

output "node_security_group_id" {
  description = "Default node security group ID created by the EKS module."
  value       = module.eks.node_security_group_id
}

# ── VPC ───────────────────────────────────────────────────────────────────────

output "vpc_id" {
  description = "ID of the VPC."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "IDs of private subnets (node workloads run here)."
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "IDs of public subnets (NAT gateway / load balancers)."
  value       = module.vpc.public_subnets
}

# ── Karpenter ─────────────────────────────────────────────────────────────────
# References the terraform-aws-modules/eks//modules/karpenter sub-module
# instantiated as module "karpenter" in iam.tf.

output "karpenter_iam_role_arn" {
  description = "ARN of the Karpenter controller IAM role (Pod Identity)."
  value       = module.karpenter.iam_role_arn
}

output "karpenter_node_iam_role_arn" {
  description = "ARN of the IAM role assumed by Karpenter-provisioned nodes."
  value       = module.karpenter.node_iam_role_arn
}

output "karpenter_node_instance_profile_name" {
  description = "EC2 instance profile name used by Karpenter-provisioned nodes."
  value       = module.karpenter.instance_profile_name
}

# ── EFA security group ────────────────────────────────────────────────────────

output "efa_security_group_id" {
  description = "Security group ID that allows all inter-node EFA traffic."
  value       = aws_security_group.efa_node.id
}

# ── Accelerator pools ─────────────────────────────────────────────────────────

output "accelerator_pool_efa_schedulable" {
  description = <<-EOT
    Map of pool name → number of EFA interfaces a Pod on that pool may request via
    `vpc.amazonaws.com/efa`. For the multi-card layout this is (interfaces - 1) because
    network card 0 carries the node IP and is not advertised as EFA (e.g. p5en resolves to
    15, not 16). Request no more than this value or the Pod will never schedule.
  EOT
  value       = local.pool_efa_schedulable
}

output "region" {
  description = <<-EOT
    AWS region this cluster was created in. Surfaced so helper scripts (tests/run-tests.sh) can
    target the right region without the caller repeating it, and without a hardcoded default that
    silently points somewhere else.
  EOT
  value       = var.region
}

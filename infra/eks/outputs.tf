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

output "accelerator_pool_placement" {
  description = <<-EOT
    Per-pool placement metadata for templating an accelerated test case's env (e.g. the
    pytorch/miles and pytorch/slime GRPO env_vars) instead of hand-guessing labels. The
    node-role label KEY is always "node-role" (the stable placement API; ADR D11 /
    docs/node-role-separation.md), the VALUE is the pool name, and efa_schedulable is the
    per-Pod EFA request cap. Example for a GRPO env_vars:
      GPU_NODE_LABEL_KEY=node-role  GPU_NODE_ROLE=<pool>  EFA_PER_NODE=<efa_schedulable>
  EOT
  value = {
    node_role_label_key = "node-role"
    pools = {
      for k, p in var.accelerator_pools : k => {
        node_role       = k
        instance_types  = p.instance_types
        device_plugin   = p.device_plugin
        efa_schedulable = lookup(local.pool_efa_schedulable, k, 0)
      }
    }
  }
}

output "region" {
  description = <<-EOT
    AWS region this cluster was created in. Surfaced so helper scripts (tests/run-tests.sh) can
    target the right region without the caller repeating it, and without a hardcoded default that
    silently points somewhere else.
  EOT
  value       = var.region
}

# ── Shared storage ────────────────────────────────────────────────────────────────────────────
# Basic10 tells the reader to run `terraform output` to see which filesystems exist, so the
# filesystems have to actually appear there. Each layer is optional (fsx_enabled /
# openzfs_enabled / efs_enabled); a disabled one reports enabled = false with empty ids rather
# than vanishing, so this output doubles as "is this layer on?" without reading tfvars. All three
# branches keep the same attribute set because HCL requires both sides of a conditional to agree
# on type.
output "shared_storage" {
  description = <<-EOT
    The three shared-storage layers, their AWS ids/DNS names and the static PersistentVolume each
    one backs. A disabled layer reports enabled = false. Pair with `kubectl get pv` to confirm the
    PV is Bound.
  EOT
  value = {
    fsx_lustre = {
      enabled  = var.fsx_enabled
      id       = var.fsx_enabled ? aws_fsx_lustre_file_system.training[0].id : ""
      dns_name = var.fsx_enabled ? aws_fsx_lustre_file_system.training[0].dns_name : ""
      # mount_name is what the CSI driver needs alongside the DNS name; easy to miss otherwise.
      mount_name        = var.fsx_enabled ? aws_fsx_lustre_file_system.training[0].mount_name : ""
      storage_capacity  = var.fsx_enabled ? tostring(aws_fsx_lustre_file_system.training[0].storage_capacity) : ""
      persistent_volume = "fsx-training"
    }
    fsx_openzfs = {
      enabled           = var.openzfs_enabled
      id                = var.openzfs_enabled ? aws_fsx_openzfs_file_system.shared[0].id : ""
      dns_name          = var.openzfs_enabled ? aws_fsx_openzfs_file_system.shared[0].dns_name : ""
      mount_name        = ""
      storage_capacity  = var.openzfs_enabled ? tostring(aws_fsx_openzfs_file_system.shared[0].storage_capacity) : ""
      persistent_volume = "openzfs-shared"
    }
    efs = {
      enabled           = var.efs_enabled
      id                = var.efs_enabled ? aws_efs_file_system.shared[0].id : ""
      dns_name          = var.efs_enabled ? aws_efs_file_system.shared[0].dns_name : ""
      mount_name        = ""
      storage_capacity  = ""
      persistent_volume = "efs-neuron-workspace"
    }
  }
}

###############################################################################
# Observability (observability.tf)
###############################################################################

output "grafana_admin_password" {
  description = "Grafana admin password. Fetch with: terraform output -raw grafana_admin_password"
  value       = var.enable_observability ? random_password.grafana_admin[0].result : null
  sensitive   = true
}

output "grafana_access" {
  description = "How to reach Grafana (port-forward for verification; production should front it with an internal LB + OIDC)."
  value = var.enable_observability ? join("\n", [
    "kubectl -n monitoring port-forward svc/kps-grafana 3000:80",
    "# -> http://localhost:3000  (user: admin)",
    "# password: terraform output -raw grafana_admin_password",
  ]) : null
}

output "prometheus_access" {
  description = "How to reach Prometheus (fullnameOverride=kps -> service name kps-prometheus)."
  value = var.enable_observability ? join("\n", [
    "kubectl -n monitoring port-forward svc/kps-prometheus 9090:9090",
    "# -> http://localhost:9090",
  ]) : null
}

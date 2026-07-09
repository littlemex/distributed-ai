locals {
  # Karpenter service account name (matches official Helm chart default).
  karpenter_service_account = "karpenter"

  # Namespace where Karpenter is installed.
  karpenter_namespace = "karpenter"

  # IAM role name for Karpenter-provisioned nodes.
  # Deterministic name used in EC2NodeClass.spec.instanceProfile.
  karpenter_node_role_name = "${var.cluster_name}-karpenter-node"

  # Name for the EFA inter-node security group.
  efa_sg_name = "${var.cluster_name}-efa-node"

  # Whether a Capacity Block reservation ID has been supplied.
  has_cb = var.cb_reservation_id != ""

  # CB expireAfter value passed to Karpenter NodePool.
  # Karpenter v1.13.0 accepts Go duration strings ("24h") for expireAfter.
  # "Never" disables expiry.
  cb_expire_after = var.cb_end_date != "" ? "24h" : "Never"

  # Tags applied to all cluster-owned resources (includes Karpenter discovery tag).
  cluster_tags = merge(var.tags, {
    "karpenter.sh/discovery" = var.cluster_name
  })
}

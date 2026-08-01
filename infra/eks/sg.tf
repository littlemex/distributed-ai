# Security group for EFA-enabled inter-node communication.
#
# p5en.48xlarge attaches 16 EFA NICs per node. All EFA traffic (RDMA write,
# RDMA send, GPUDirect RDMA) stays within this SG. Both ingress and egress
# are set to all-traffic so that NCCL / libfabric can negotiate any protocol
# (efa-direct, efa) without restriction.
#
# The EFA device plugin advertises vpc.amazonaws.com/efa=<n> per node (see the
# accelerator_pool_efa_schedulable output); GPUDirect RDMA over EFA is the
# primary inter-node transport NCCL/libfabric select for collective operations.

resource "aws_security_group" "efa_node" {
  name        = local.efa_sg_name
  description = "Allow all traffic between EFA-enabled nodes, GPU or Neuron (NCCL / RDMA / GPUDirect)."
  vpc_id      = module.vpc.vpc_id

  tags = merge(var.tags, {
    Name                     = local.efa_sg_name
    "karpenter.sh/discovery" = var.cluster_name
  })

  # This SG is attached to every accelerator node's ENI while it exists. Destroy ordering:
  # null_resource.wait_for_node_drain (karpenter.tf) depends_on this resource, so it is
  # removed only after the drain-wait has confirmed no NodeClaims remain. Without that edge,
  # delete can hit DependencyViolation while a node's ENI is still attached.
  timeouts {
    delete = "10m"
  }
}

# Ingress: allow all traffic from nodes that share this security group.
resource "aws_security_group_rule" "efa_node_ingress_self" {
  security_group_id        = aws_security_group.efa_node.id
  type                     = "ingress"
  description              = "All traffic from peer EFA nodes (self-referencing)."
  protocol                 = "-1"
  from_port                = 0
  to_port                  = 0
  source_security_group_id = aws_security_group.efa_node.id
}

# Egress: unrestricted IP egress (S3 access, ECR pull, etc.).
resource "aws_security_group_rule" "efa_node_egress_all" {
  security_group_id = aws_security_group.efa_node.id
  type              = "egress"
  description       = "Unrestricted egress."
  protocol          = "-1"
  from_port         = 0
  to_port           = 0
  cidr_blocks       = ["0.0.0.0/0"]
}

# Egress: self-referencing all-traffic. REQUIRED for EFA and NOT covered by the
# 0.0.0.0/0 rule above: EFA's OS-bypass SRD traffic is not IP traffic, so a CIDR
# egress rule does not authorize it. Without this, multi-node NCCL initializes and
# selects the efa provider (bootstrap is TCP), then every data transfer times out
# with "NET/OFI ... Error 15 (Unreachable remote)" because the outbound SRD packets
# are dropped. EFA SGs need self-referencing all-traffic on BOTH ingress and egress.
resource "aws_security_group_rule" "efa_node_egress_self" {
  security_group_id        = aws_security_group.efa_node.id
  type                     = "egress"
  description              = "All traffic to peer EFA nodes (self-referencing; required for EFA SRD)."
  protocol                 = "-1"
  from_port                = 0
  to_port                  = 0
  source_security_group_id = aws_security_group.efa_node.id
}

# ── Cluster SG → Node SG: Pod-to-Pod inter-node traffic ───────────────────────
# VPC CNI sources Pod traffic from the cluster security group. Without this rule,
# NCCL/gloo socket connections between Pods on different Karpenter nodes fail with
# "Software caused connection abort" — the node SG's self-referencing rule only admits
# traffic sourced from the node SG itself, not from the cluster SG. Managed node group
# nodes do not hit this because EKS attaches the cluster SG directly to them; Karpenter
# nodes get it only when securityGroupSelectorTerms picks it up (see eks.tf aws_ec2_tag).
resource "aws_security_group_rule" "node_ingress_from_cluster_sg" {
  security_group_id        = module.eks.node_security_group_id
  type                     = "ingress"
  protocol                 = "-1"
  from_port                = 0
  to_port                  = 0
  source_security_group_id = module.eks.cluster_security_group_id
  description              = "All traffic from cluster SG (Pod-to-Pod via VPC CNI)"
}

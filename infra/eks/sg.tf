# Security group for EFA-enabled inter-node communication.
#
# p5en.48xlarge attaches 16 EFA NICs per node. All EFA traffic (RDMA write,
# RDMA send, GPUDirect RDMA) stays within this SG. Both ingress and egress
# are set to all-traffic so that NCCL / libfabric can negotiate any protocol
# (efa-direct, efa) without restriction.
#
# Reference: CLUSTER-GUIDE §1 — EFA device plugin exposes vpc.amazonaws.com/efa=16/node;
# GPUDirect RDMA over EFA is the primary inter-node transport for collective operations.

resource "aws_security_group" "efa_node" {
  name        = local.efa_sg_name
  description = "Allow all traffic between EFA-enabled GPU nodes (NCCL / RDMA / GPUDirect)."
  vpc_id      = module.vpc.vpc_id

  tags = merge(var.tags, {
    Name                     = local.efa_sg_name
    "karpenter.sh/discovery" = var.cluster_name
  })
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

# Egress: unrestricted (EFA RDMA, S3 access, ECR pull, etc.).
resource "aws_security_group_rule" "efa_node_egress_all" {
  security_group_id = aws_security_group.efa_node.id
  type              = "egress"
  description       = "Unrestricted egress."
  protocol          = "-1"
  from_port         = 0
  to_port           = 0
  cidr_blocks       = ["0.0.0.0/0"]
}

# terraform-aws-modules/vpc/aws
# Verified module variable names: cidr, azs, private_subnets, public_subnets, tags, name.
#
# The VPC spans var.azs (>= 2 AZs) because the EKS control plane requires subnets in at
# least two AZs. GPU nodes are still pinned to a single AZ (var.gpu_zone) by the Karpenter
# NodePool, which satisfies the single-AZ placement constraint of Capacity Block for ML.

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = var.cluster_name
  cidr = var.vpc_cidr

  azs             = var.azs
  private_subnets = var.private_subnet_cidrs
  public_subnets  = var.public_subnet_cidrs

  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false

  enable_dns_hostnames = true
  enable_dns_support   = true

  # Karpenter subnet discovery: karpenter.sh/discovery=<cluster-name>
  # EKS load-balancer controller subnet tags are added inline.
  private_subnet_tags = {
    "karpenter.sh/discovery"                    = var.cluster_name
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }

  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }

  tags = local.cluster_tags
}

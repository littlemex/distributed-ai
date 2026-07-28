# terraform-aws-modules/vpc/aws
# Verified module variable names: cidr, azs, private_subnets, public_subnets, tags, name.
#
# The VPC spans local.azs — by default EVERY standard AZ in the region (see az.tf), so a
# Capacity Block landing in ANY AZ always has a matching subnet and the cluster tolerates a
# CB's AZ changing between reservations. The AZ list, and one private + one public subnet CIDR
# per AZ, are all resolved in az.tf (auto-derived from var.region / var.vpc_cidr unless
# overridden). Each accelerator pool still pins to a single AZ (local.pool_zone[k]) via its
# Karpenter NodePool, which satisfies EFA's intra-AZ requirement and Capacity Block's single-AZ
# placement constraint.

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = var.cluster_name
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets

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

################################################################################
# EKS Capabilities (managed Argo CD) multi-environment verification
#
# Three VPCs joined by a Transit Gateway stand in for three environments:
#   hub      10.0.0.0/16  EKS cluster that owns the managed Argo CD capability
#   onprem   10.80.0.0/16 "on-premises": an EC2 instance joined as an EKS Hybrid Node
#                         (pods: 10.81.0.0/16, routed to that instance)
#   other    10.90.0.0/16 "another cloud": an EC2 instance running k3s (not EKS)
################################################################################

terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
  backend "s3" {}
}

provider "aws" {
  region = var.region
  default_tags { tags = { Project = var.cluster_name } }
}

# IAM Identity Center may live in another Region; the capability takes it as idc_region.
provider "aws" {
  alias  = "idc"
  region = var.idc_region
}

variable "region" {
  description = "Region for the cluster and every environment"
  default     = "us-east-2"
}
variable "cluster_name" { default = "ekscap-hub" }
variable "kubernetes_version" { default = "1.35" }
variable "idc_region" {
  description = "Region of the IAM Identity Center instance"
}
variable "idc_admin_user_name" {
  description = "Identity Center user name mapped to the Argo CD ADMIN role"
  validation {
    condition     = length(var.idc_admin_user_name) > 0 && var.idc_admin_user_name != "None"
    error_message = "Set idc_admin_user_name to an existing Identity Center user name."
  }
}

locals {
  hub_cidr        = "10.0.0.0/16"
  onprem_cidr     = "10.80.0.0/16"
  onprem_pod_cidr = "10.81.0.0/16"
  other_cidr      = "10.90.0.0/16"
  azs             = slice(data.aws_availability_zones.this.names, 0, 2)
}

data "aws_availability_zones" "this" { state = "available" }

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

################################################################################
# Networks
################################################################################

module "hub_vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name               = "${var.cluster_name}-hub"
  cidr               = local.hub_cidr
  azs                = local.azs
  private_subnets    = ["10.0.0.0/20", "10.0.16.0/20"]
  public_subnets     = ["10.0.128.0/24", "10.0.129.0/24"]
  enable_nat_gateway = true
  single_nat_gateway = true
}

module "onprem_vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name           = "${var.cluster_name}-onprem"
  cidr           = local.onprem_cidr
  azs            = local.azs
  public_subnets = ["10.80.0.0/24"]
}

module "other_vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name           = "${var.cluster_name}-other"
  cidr           = local.other_cidr
  azs            = local.azs
  public_subnets = ["10.90.0.0/24"]
}

resource "aws_ec2_transit_gateway" "this" {
  description = "${var.cluster_name} environments"
  tags        = { Name = var.cluster_name }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "hub" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  vpc_id             = module.hub_vpc.vpc_id
  subnet_ids         = module.hub_vpc.private_subnets
}

resource "aws_ec2_transit_gateway_vpc_attachment" "onprem" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  vpc_id             = module.onprem_vpc.vpc_id
  subnet_ids         = module.onprem_vpc.public_subnets
}

resource "aws_ec2_transit_gateway_vpc_attachment" "other" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  vpc_id             = module.other_vpc.vpc_id
  subnet_ids         = module.other_vpc.public_subnets
}

# The hybrid pod CIDR lives behind the on-prem attachment, as it would behind a VPN.
resource "aws_ec2_transit_gateway_route" "onprem_pods" {
  destination_cidr_block         = local.onprem_pod_cidr
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.onprem.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway.this.association_default_route_table_id
}

# single_nat_gateway and the default public layout give one route table per VPC,
# so routes are keyed statically by (VPC, destination).
locals {
  tgw_routes = merge(
    { for c in [local.onprem_cidr, local.onprem_pod_cidr, local.other_cidr] : "hub-${c}" => { vpc = "hub", cidr = c } },
    { for c in [local.hub_cidr, local.other_cidr] : "onprem-${c}" => { vpc = "onprem", cidr = c } },
    { for c in [local.hub_cidr, local.onprem_cidr, local.onprem_pod_cidr] : "other-${c}" => { vpc = "other", cidr = c } },
  )
  route_table = {
    hub    = module.hub_vpc.private_route_table_ids[0]
    onprem = module.onprem_vpc.public_route_table_ids[0]
    other  = module.other_vpc.public_route_table_ids[0]
  }
}

resource "aws_route" "tgw" {
  for_each               = local.tgw_routes
  route_table_id         = local.route_table[each.value.vpc]
  destination_cidr_block = each.value.cidr
  transit_gateway_id     = aws_ec2_transit_gateway.this.id
  depends_on             = [aws_ec2_transit_gateway_vpc_attachment.hub, aws_ec2_transit_gateway_vpc_attachment.onprem, aws_ec2_transit_gateway_vpc_attachment.other]
}

# Inside the on-prem network the pod CIDR is reached through the node itself.
resource "aws_route" "onprem_pods_to_node" {
  route_table_id         = local.route_table.onprem
  destination_cidr_block = local.onprem_pod_cidr
  network_interface_id   = aws_instance.hybrid.primary_network_interface_id
}

################################################################################
# Hub EKS cluster with remote (hybrid) networks
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.24.0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version
  vpc_id             = module.hub_vpc.vpc_id
  subnet_ids         = module.hub_vpc.private_subnets

  endpoint_private_access                  = true
  endpoint_public_access                   = false
  enable_cluster_creator_admin_permissions = true

  remote_network_config = {
    remote_node_networks = { cidrs = [local.onprem_cidr] }
    remote_pod_networks  = { cidrs = [local.onprem_pod_cidr] }
  }

  security_group_additional_rules = {
    hybrid_https = {
      description = "Hybrid nodes and pods to the API server"
      protocol    = "tcp"
      from_port   = 443
      to_port     = 443
      type        = "ingress"
      cidr_blocks = [local.onprem_cidr, local.onprem_pod_cidr]
    }
    # The endpoint is private only; the operator reaches it through an SSM port
    # forward on the k3s machine, which sits in the "other" network.
    operator_https = {
      description = "Operator access through SSM port forwarding"
      protocol    = "tcp"
      from_port   = 443
      to_port     = 443
      type        = "ingress"
      cidr_blocks = [local.other_cidr]
    }
  }

  addons = {
    vpc-cni                = { before_compute = true }
    kube-proxy             = {}
    coredns                = {}
    eks-pod-identity-agent = { before_compute = true }
  }

  eks_managed_node_groups = {
    cloud = {
      instance_types = ["t3.large"]
      min_size       = 1
      max_size       = 2
      desired_size   = 1
    }
  }

  access_entries = {
    hybrid = {
      principal_arn = module.hybrid_node_role.arn
      type          = "HYBRID_LINUX"
    }
  }
}

module "hybrid_node_role" {
  source  = "terraform-aws-modules/eks/aws//modules/hybrid-node-role"
  version = "21.24.0"

  name = "${var.cluster_name}-hybrid-node"
}

resource "aws_ssm_activation" "hybrid" {
  name               = "${var.cluster_name}-hybrid"
  iam_role           = module.hybrid_node_role.name
  registration_limit = 5
  expiration_date    = timeadd(plantimestamp(), "720h")
  lifecycle { ignore_changes = [expiration_date] }
}

################################################################################
# "On-premises" machine joined as a Hybrid Node. No instance profile: its only AWS
# identity is the SSM hybrid activation, exactly as on a physical server.
################################################################################

resource "aws_security_group" "onprem" {
  name   = "${var.cluster_name}-onprem-node"
  vpc_id = module.onprem_vpc.vpc_id
  ingress {
    description = "Private networks (hub, other environments, pods)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.0.0.0/8"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "hybrid" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.large"
  subnet_id                   = module.onprem_vpc.public_subnets[0]
  vpc_security_group_ids      = [aws_security_group.onprem.id]
  associate_public_ip_address = true
  source_dest_check           = false
  root_block_device { volume_size = 40 }

  user_data = templatefile("${path.module}/userdata/hybrid-node.sh.tpl", {
    cluster_name       = var.cluster_name
    region             = var.region
    kubernetes_version = var.kubernetes_version
    activation_id      = aws_ssm_activation.hybrid.id
    activation_code    = aws_ssm_activation.hybrid.activation_code
  })
  user_data_replace_on_change = true

  tags       = { Name = "${var.cluster_name}-onprem-hybrid-node" }
  depends_on = [module.eks]
}

################################################################################
# "Another cloud": a plain k3s cluster on EC2. The instance profile is only for SSM
# Run Command so the cluster can be operated without SSH.
################################################################################

resource "aws_iam_role" "other" {
  name = "${var.cluster_name}-other-k3s"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "other_ssm" {
  role       = aws_iam_role.other.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "other" {
  name = aws_iam_role.other.name
  role = aws_iam_role.other.name
}

resource "aws_security_group" "other" {
  name   = "${var.cluster_name}-other-k3s"
  vpc_id = module.other_vpc.vpc_id
  ingress {
    description = "Private networks only"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.0.0.0/8"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "other" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.large"
  subnet_id                   = module.other_vpc.public_subnets[0]
  vpc_security_group_ids      = [aws_security_group.other.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.other.name
  root_block_device { volume_size = 30 }

  user_data                   = file("${path.module}/userdata/k3s.sh")
  user_data_replace_on_change = true

  tags = { Name = "${var.cluster_name}-other-k3s" }
}

################################################################################
# Managed Argo CD (EKS Capability)
################################################################################

resource "aws_iam_role" "argocd_capability" {
  name = "${var.cluster_name}-argocd-capability"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Principal = { Service = "capabilities.eks.amazonaws.com" }
    }]
  })
}

data "aws_ssoadmin_instances" "this" { provider = aws.idc }

data "aws_identitystore_user" "admin" {
  provider          = aws.idc
  identity_store_id = one(data.aws_ssoadmin_instances.this.identity_store_ids)
  alternate_identifier {
    unique_attribute {
      attribute_path  = "UserName"
      attribute_value = var.idc_admin_user_name
    }
  }
}

resource "aws_eks_capability" "argocd" {
  cluster_name              = module.eks.cluster_name
  capability_name           = "argocd"
  type                      = "ARGOCD"
  role_arn                  = aws_iam_role.argocd_capability.arn
  delete_propagation_policy = "RETAIN"

  configuration {
    argo_cd {
      namespace = "argocd"
      aws_idc {
        idc_instance_arn = one(data.aws_ssoadmin_instances.this.arns)
        idc_region       = var.idc_region
      }
      rbac_role_mapping {
        role = "ADMIN"
        identity {
          id   = data.aws_identitystore_user.admin.user_id
          type = "SSO_USER"
        }
      }
    }
  }
}

# The capability gets an access entry on its own cluster but no Kubernetes
# permissions. Cluster admin keeps the verification short (the second-stage Argo CD
# needs cluster-scoped RBAC); scope it down for real use.
resource "aws_eks_access_policy_association" "argocd_capability" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.argocd_capability.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope { type = "cluster" }
  depends_on = [aws_eks_capability.argocd]
}

output "cluster_name" { value = module.eks.cluster_name }
output "cluster_arn" { value = module.eks.cluster_arn }
output "argocd_server_url" { value = aws_eks_capability.argocd.configuration[0].argo_cd[0].server_url }
output "hybrid_instance_id" { value = aws_instance.hybrid.id }
output "other_instance_id" { value = aws_instance.other.id }
output "other_private_ip" { value = aws_instance.other.private_ip }
output "hybrid_node_role_name" { value = module.hybrid_node_role.name }

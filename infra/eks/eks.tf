################################################################################
# EKS Cluster
# Module: terraform-aws-modules/eks/aws v21.24.0
#
# Verified facts:
#   - Variable name is `name` (not `cluster_name`) and `kubernetes_version` (not `cluster_version`)
#   - Output names: cluster_name, cluster_endpoint, cluster_certificate_authority_data,
#     cluster_oidc_issuer_url, oidc_provider_arn, node_security_group_id
#   - Kubernetes 1.35 is confirmed available in us-east-2
#   - aws-fsx-csi-driver addon version v1.9.0-eksbuild.1 (VERIFIED_FACTS.md)
#   - fsx.tf manages aws-fsx-csi-driver as a standalone aws_eks_addon resource;
#     do NOT declare it here to avoid duplicate-addon conflict
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.24.0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version # default "1.35"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Private endpoint enabled; public access enabled for operator convenience
  endpoint_private_access = true
  endpoint_public_access  = true

  # Grant the Terraform caller admin permissions via cluster access entry
  enable_cluster_creator_admin_permissions = true

  ################################################################################
  # EKS Add-ons
  # aws-fsx-csi-driver is NOT listed here — fsx.tf manages it as a standalone
  # aws_eks_addon resource (with a pinned version and dedicated IRSA role).
  ################################################################################
  addons = {
    vpc-cni = {
      before_compute = true
    }
    kube-proxy = {}
    coredns    = {}
    # Pod Identity agent must exist before controllers that authenticate via Pod Identity.
    eks-pod-identity-agent = {
      before_compute = true
    }
    aws-ebs-csi-driver = {
      # Grant the driver EC2 permissions via Pod Identity, otherwise the controller
      # crashes ("no EC2 IMDS role found") and the addon hangs in CREATING, blocking apply.
      pod_identity_association = [{
        role_arn        = aws_iam_role.ebs_csi.arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
  }

  ################################################################################
  # System managed node group — m5.xlarge x2
  # These nodes host kube-system and Karpenter itself.
  # They are NOT managed by Karpenter (label prevents self-scheduling).
  ################################################################################
  eks_managed_node_groups = {
    system = {
      ami_type       = var.system_node_ami_type
      instance_types = var.system_node_instance_types

      min_size     = var.system_node_desired_size
      max_size     = var.system_node_desired_size
      desired_size = var.system_node_desired_size

      labels = {
        "karpenter.sh/controller" = "true"
      }
    }
  }

  ################################################################################
  # Karpenter discovery tag on the node security group
  # Karpenter uses this tag to find the SG for EC2NodeClass securityGroupSelectorTerms.
  ################################################################################
  node_security_group_tags = merge(local.cluster_tags, {
    "karpenter.sh/discovery" = var.cluster_name
  })

  tags = local.cluster_tags
}

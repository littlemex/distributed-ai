################################################################################
# EKS Cluster
# Module: terraform-aws-modules/eks/aws v21.24.0
#
# Verified facts:
#   - Variable name is `name` (not `cluster_name`) and `kubernetes_version` (not `cluster_version`)
#   - Output names: cluster_name, cluster_endpoint, cluster_certificate_authority_data,
#     cluster_oidc_issuer_url, oidc_provider_arn, node_security_group_id
#   - Kubernetes 1.35 is confirmed available in us-east-2
#   - aws-fsx-csi-driver addon version v1.9.0-eksbuild.1
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
  # These nodes host kube-system and Karpenter itself. They are NOT managed by
  # Karpenter (label prevents self-scheduling). This tier is a SANCTUARY: only
  # things that must already be running for the cluster to recover when Karpenter
  # is down (kube-system + the Karpenter controller) belong here. Operators
  # (gpu/mpi/kuberay) and workloads (e.g. a Ray head) go on the Karpenter `cpu`
  # pool instead. See docs/node-role-separation.md.
  ################################################################################
  eks_managed_node_groups = {
    system = {
      ami_type       = var.system_node_ami_type
      instance_types = var.system_node_instance_types

      # Bigger than the ~20 GB default so kube-system images + logs never crowd the
      # disk. NOTE: changing disk_size rolls (replaces) the system nodes, so apply
      # this in a calm window (CoreDNS >=2 replicas + PDB) — migration step 6.
      disk_size = var.system_node_volume_size

      min_size     = var.system_node_desired_size
      max_size     = var.system_node_desired_size
      desired_size = var.system_node_desired_size

      labels = {
        "karpenter.sh/controller" = "true"
        # Positive role label (same `node-role` key the Karpenter pools use — cpu
        # pool = "cpu", accelerator pools = their name) so workloads target a tier
        # explicitly and never fall back onto system via a negative "not-GPU" affinity.
        "node-role" = "system"
      }

      # SANCTUARY TAINT — DO NOT enable until the operators (gpu/mpi/kuberay) have
      # been moved to the `cpu` pool (migration steps 2-3 in
      # docs/node-role-separation.md). NoSchedule does not evict running pods, so
      # enabling it early is a time bomb: the operators stay put until their next
      # rollout, then Pending-bomb with nowhere to go. Verified today: kube-system
      # + karpenter tolerate this; gpu/mpi/kuberay operators do NOT.
      # taints = {
      #   critical = { key = "CriticalAddonsOnly", value = "true", effect = "NO_SCHEDULE" }
      # }
    }
  }

  ################################################################################
  # Karpenter discovery tag on security groups
  # EC2NodeClass securityGroupSelectorTerms matches on karpenter.sh/discovery, so exactly
  # ONE security group must carry it: this node SG. Do NOT also tag the EKS cluster security
  # group. A Karpenter node would then get both, and AWS tags both
  # kubernetes.io/cluster/<name> — the tag the AWS Load Balancer Controller uses to find "the"
  # security group of a pod's ENI. With two matches it refuses to guess, never creates the
  # backend security group rule, and requeues every 15 seconds:
  #   expected exactly one securityGroup tagged with kubernetes.io/cluster/<name>
  #   for eni eni-..., got: [sg-<cluster>, sg-<node>]
  # Nothing looks broken from the outside: the ALB reaches "active" and the nodes are Ready,
  # but no rule ever opens the path to the pods, every target stays unhealthy with
  # Target.Timeout, and the Ingress serves 504 forever. Verified on a live cluster: removing
  # the tag from the cluster SG let the controller create the rule (tcp/80, tagged
  # elbv2.k8s.aws/targetGroupBinding=shared) and the targets went healthy (2026-08-03).
  #
  # Inter-node pod traffic does not need the cluster SG. Pod packets are evaluated against the
  # SGs on the node's ENIs, so the node SG's own self-referencing rule covers it — provided
  # that rule spans all ports (aws_security_group_rule.node_ingress_self_all in sg.tf).
  ################################################################################
  node_security_group_tags = merge(local.cluster_tags, {
    "karpenter.sh/discovery" = var.cluster_name
  })

  tags = local.cluster_tags
}

# ── Invariant: at most one Karpenter-selected SG may carry the cluster tag ─────────────────
# The failure this guards against is silent: the ALB comes up, the nodes are Ready, and only the
# target group tells you anything is wrong. Surface it at plan time instead of from a 504.
#
# A `check` block, not a precondition. A precondition here would be self-defeating: the tag it
# objects to lives in the live account, so once the mistake exists the plan fails and the very
# apply that would REMOVE the tag is blocked too. A check reports on every plan and apply while
# still letting the fix through, which is what continuous verification is for.
data "aws_security_groups" "karpenter_selected" {
  filter {
    name   = "tag:karpenter.sh/discovery"
    values = [var.cluster_name]
  }
  filter {
    name   = "vpc-id"
    values = [module.vpc.vpc_id]
  }
}

data "aws_security_group" "karpenter_selected" {
  for_each = toset(data.aws_security_groups.karpenter_selected.ids)
  id       = each.value
}

locals {
  # SGs Karpenter will attach that AWS also tags kubernetes.io/cluster/<name> — the tag the AWS
  # Load Balancer Controller resolves a pod ENI's security group by. More than one is the defect.
  karpenter_cluster_tagged_sgs = [
    for sg in data.aws_security_group.karpenter_selected : sg.id
    if contains(keys(sg.tags), "kubernetes.io/cluster/${var.cluster_name}")
  ]
}

check "one_cluster_tagged_karpenter_sg" {
  assert {
    condition     = length(local.karpenter_cluster_tagged_sgs) <= 1
    error_message = <<-EOT
      ${length(local.karpenter_cluster_tagged_sgs)} security groups carry BOTH
      karpenter.sh/discovery=${var.cluster_name} and kubernetes.io/cluster/${var.cluster_name}:
      ${join(", ", local.karpenter_cluster_tagged_sgs)}
      Expected only the node security group (${module.eks.node_security_group_id}).

      Karpenter attaches all of them to every node it launches, and the AWS Load Balancer
      Controller needs exactly one cluster-tagged security group per pod ENI to place its backend
      rule. Given two it creates none, and the symptom does not point here: the ALB reaches
      "active", the nodes are Ready, but every target stays unhealthy with Target.Timeout and the
      Ingress serves 504. The controller logs "expected exactly one securityGroup tagged with
      kubernetes.io/cluster/..." every 15 seconds.

      Drop karpenter.sh/discovery from the extra security group(s). Pod-to-pod traffic across
      nodes does not need the cluster SG — the node SG's own self rule (ingress_self_all above)
      covers it.
    EOT
  }
}

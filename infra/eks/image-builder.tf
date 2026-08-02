################################################################################
# In-cluster image builder (Kaniko + ECR + Pod Identity)
#
# Lets the workshop build the ddp-sample container INSIDE the cluster instead of
# depending on a local docker/finch. This file provisions only the MECHANISM
# (ECR repo, IAM role, Pod Identity association, namespace, ServiceAccount) — it
# does NOT run a build. The build itself is a Kaniko Job in the experiments Helm
# catalog (charts/experiments/templates/image-build-ddp-sample.yaml), applied with
# `helm template | kubectl apply` exactly like the training Jobs. This is the same
# split we use for the Training Operator: Terraform installs the operator, but the
# TrainJob is a catalog workload — never a Terraform resource.
#
# Auth chain (settings-free): a Pod on the image-builder SA gets Pod Identity env
# injected (AWS_CONTAINER_CREDENTIALS_FULL_URI + token file); Kaniko's bundled
# amazon-ecr-credential-helper (ecr-login) resolves ECR logins through the SDK's
# container-credentials provider. No config.json, no docker login.
#
# Depends on: the eks-pod-identity-agent addon (eks.tf) and a CPU NodePool
# (karpenter-resources.tf, cpu_nodepool_enabled). Kaniko runs as root, so the
# namespace is Pod-Security "baseline" (not "restricted").
################################################################################

variable "image_builder_enabled" {
  description = <<-EOT
    Provision the in-cluster image builder: an ECR repository (ddp-sample), an IAM
    role scoped to push to it, a Pod Identity association, and a dedicated
    "image-builder" namespace + ServiceAccount for Kaniko. Default ON so the Basic02
    workshop needs no local docker/finch. The build Job itself is NOT created here —
    render it from charts/experiments (imageBuild.enabled=true). Requires the
    eks-pod-identity-agent addon and a CPU NodePool (cpu_nodepool_enabled).
  EOT
  type        = bool
  default     = true
}

variable "image_builder_repository_name" {
  description = <<-EOT
    ECR repository name for the built ddp-sample image. Leave null (the default) to derive
    "<cluster_name>-ddp-sample".

    The name must be qualified because ECR repository names are unique per account+region,
    while everything else this module creates is already prefixed with cluster_name. A bare
    "ddp-sample" default meant a SECOND cluster in the same account and region failed its apply
    with RepositoryAlreadyExistsException — hit while building a verification cluster alongside
    an existing one (2026-08-03). Set this explicitly only if you need a specific repository
    name; read the resulting URL from `terraform output -raw ddp_sample_ecr_url` rather than
    reconstructing it by hand.
  EOT
  type        = string
  default     = null
}

locals {
  image_builder_repository_name = coalesce(
    var.image_builder_repository_name,
    "${var.cluster_name}-ddp-sample",
  )
}

# ── Dedicated builder NodePool (opt-in, for LARGE images) ──────────────────────
# Kaniko expands the base image onto the node's root filesystem (ephemeral-storage);
# that path cannot be moved to a PVC or FSx, so a large image (e.g. a vLLM/CUDA build
# whose pushed size is tens of GB) needs a big LOCAL disk. Peak disk ~= pushed size x4-5.
# The default CPU NodePool ships a 50Gi root, which fits the ddp-sample (~3.3GB pushed,
# ~15Gi peak) but not a 20GB image (~100Gi peak). Rather than inflate every CPU node,
# opt into a dedicated, tainted builder pool that Karpenter spins up only while a build
# Job exists and consolidates back to zero after — so the big disk is billed only during
# the build. It uses NVMe instance-store striped RAID0 for the scratch (far faster than
# EBS for unpack/snapshot, and scratch is inherently disposable).
variable "image_builder_dedicated_pool" {
  description = <<-EOT
    Provision a dedicated, tainted Karpenter NodePool for large image builds (NVMe
    instance-store RAID0 scratch). OFF by default — the shared CPU NodePool's 50Gi root
    handles small images like ddp-sample. Turn ON when building images whose pushed size
    is more than a few GB (peak build disk ~= pushed size x4-5). When on, render the build
    Job with imageBuild.dedicatedPool.enabled=true so it targets this pool.
  EOT
  type        = bool
  default     = false
}

variable "image_builder_instance_families" {
  description = "Instance families for the dedicated builder pool. Must have NVMe instance store (m6id/c6id/m7gd-class) so localStorage RAID0 has disks to stripe."
  type        = list(string)
  default     = ["m6id", "c6id", "m7id", "c7id"]
}

variable "image_builder_fallback_volume_size" {
  description = "Root gp3 volume size for the dedicated builder pool's fallback (non-NVMe) case. The NodePool requirement normally pins an NVMe instance, so this only backs the rare instance without instance store. Kept consistent with the other node-volume variables (cpu_node_volume_*)."
  type        = string
  default     = "200Gi"
}

variable "image_builder_fallback_volume_throughput" {
  description = "gp3 throughput (MiB/s) for the dedicated builder pool's fallback root volume. Range 125-1000."
  type        = number
  default     = 500
}

locals {
  image_builder_namespace = "image-builder"
  image_builder_sa        = "image-builder"
}

# ── ECR repository ───────────────────────────────────────────────────────────
resource "aws_ecr_repository" "ddp_sample" {
  count                = var.image_builder_enabled ? 1 : 0
  name                 = local.image_builder_repository_name
  image_tag_mutability = "MUTABLE"
  # force_delete: a workshop cluster's `terraform destroy` must not wedge on an ECR
  # repo that still holds pushed images.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = false
  }

  tags = var.tags
}

# ── IAM role (Pod Identity) ──────────────────────────────────────────────────
data "aws_iam_policy_document" "image_builder_assume" {
  count = var.image_builder_enabled ? 1 : 0
  statement {
    # TagSession is required by EKS Pod Identity in addition to AssumeRole.
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "image_builder" {
  count              = var.image_builder_enabled ? 1 : 0
  name               = "${var.cluster_name}-image-builder"
  assume_role_policy = data.aws_iam_policy_document.image_builder_assume[0].json
  tags               = var.tags
}

data "aws_iam_policy_document" "image_builder" {
  count = var.image_builder_enabled ? 1 : 0
  statement {
    sid = "EcrAuth"
    # GetAuthorizationToken cannot be resource-scoped (it is account-global).
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "EcrPushPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
    ]
    resources = [aws_ecr_repository.ddp_sample[0].arn]
  }
}

resource "aws_iam_role_policy" "image_builder" {
  count  = var.image_builder_enabled ? 1 : 0
  name   = "ecr-push"
  role   = aws_iam_role.image_builder[0].id
  policy = data.aws_iam_policy_document.image_builder[0].json
}

# ── Namespace + ServiceAccount (kubectl_manifest, matching the training-operator
#    vendoring pattern — this module has no hashicorp/kubernetes provider) ──────
resource "kubectl_manifest" "image_builder_namespace" {
  count = var.image_builder_enabled ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name = local.image_builder_namespace
      labels = {
        # The in-cluster builder is rootless BuildKit (moby/buildkit:rootless). It is NON-
        # privileged (no CAP_SYS_ADMIN, runs as uid 1000 in a user namespace) but rootlesskit
        # needs clone/unshare syscalls that the RuntimeDefault seccomp profile blocks, so the
        # build container must set seccompProfile: Unconfined — and PSA "baseline" forbids that
        # (confirmed live 2026-07-30: under baseline the build pod is rejected; with RuntimeDefault
        # it is admitted but rootlesskit dies with "fork/exec /proc/self/exe: operation not
        # permitted"). So enforce must be relaxed for THIS namespace only. It is dedicated to
        # single-shot build Jobs on their own tainted/selected nodes, not general workloads.
        # warn/audit stay at baseline so any *other* deviation is still surfaced in logs.
        "pod-security.kubernetes.io/enforce" = "privileged"
        "pod-security.kubernetes.io/warn"    = "baseline"
        "pod-security.kubernetes.io/audit"   = "baseline"
      }
    }
  })
}

resource "kubectl_manifest" "image_builder_sa" {
  count = var.image_builder_enabled ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ServiceAccount"
    metadata = {
      name      = local.image_builder_sa
      namespace = local.image_builder_namespace
    }
  })
  depends_on = [kubectl_manifest.image_builder_namespace]
}

resource "aws_eks_pod_identity_association" "image_builder" {
  count           = var.image_builder_enabled ? 1 : 0
  cluster_name    = module.eks.cluster_name
  namespace       = local.image_builder_namespace
  service_account = local.image_builder_sa
  role_arn        = aws_iam_role.image_builder[0].arn
}

# The ECR URL the Kaniko Job pushes to and the training workloads pull from. Feed it
# into the catalog with: --set imageBuild.repository=$(terraform output -raw ddp_sample_ecr_url)
output "ddp_sample_ecr_url" {
  description = "ECR repository URL for the in-cluster-built ddp-sample image (null when image_builder_enabled=false)."
  value       = var.image_builder_enabled ? aws_ecr_repository.ddp_sample[0].repository_url : null
}

# ── Dedicated builder EC2NodeClass + NodePool (opt-in) ─────────────────────────
# Only rendered when both the mechanism (image_builder_enabled) and the dedicated pool
# (image_builder_dedicated_pool) are on. Reuses nodeclass_common (subnets/SG/instance
# profile) but overrides userData to stripe the NVMe instance store into the root/scratch
# via RAID0 and sizes a large EBS root as a fallback for families without instance store.
resource "kubectl_manifest" "ec2nodeclass_image_builder" {
  count = var.image_builder_enabled && var.image_builder_dedicated_pool ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata   = { name = "image-builder" }
    spec = merge(local.nodeclass_common, {
      amiSelectorTerms = [{ alias = "al2023@latest" }]
      # RAID0 stripes all local NVMe instance-store volumes and mounts them for containerd/
      # kubelet, so Kaniko's rootfs unpack + snapshot land on fast local disk, not EBS.
      userData = <<-EOT
        ---
        apiVersion: node.eks.aws/v1alpha1
        kind: NodeConfig
        spec:
          instance:
            localStorage:
              strategy: Raid0
      EOT
      # Fallback root for the rare case an instance without NVMe is picked (the NodePool
      # requirement below should prevent it, but a 200Gi gp3 keeps a build alive regardless).
      blockDeviceMappings = [{
        deviceName = "/dev/xvda"
        ebs = {
          volumeSize          = var.image_builder_fallback_volume_size
          volumeType          = "gp3"
          throughput          = var.image_builder_fallback_volume_throughput
          deleteOnTermination = true
          encrypted           = true
        }
      }]
    })
  })

  depends_on = [helm_release.karpenter, null_resource.wait_for_node_drain]
}

resource "kubectl_manifest" "nodepool_image_builder" {
  count = var.image_builder_enabled && var.image_builder_dedicated_pool ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata   = { name = "image-builder" }
    spec = {
      template = {
        metadata = { labels = { "node-role" = "image-builder" } }
        spec = {
          # Taint so ONLY the build Job (which tolerates it) lands here — no CPU workload
          # accidentally schedules onto the expensive big-disk node.
          taints = [{
            key    = "workload"
            value  = "image-build"
            effect = "NoSchedule"
          }]
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "image-builder"
          }
          requirements = [
            { key = "karpenter.sh/capacity-type", operator = "In", values = ["on-demand"] },
            { key = "karpenter.k8s.aws/instance-family", operator = "In", values = var.image_builder_instance_families },
            # Require local NVMe so RAID0 has disks to stripe (families above all have it;
            # this guards against a family edit that drops instance store).
            { key = "karpenter.k8s.aws/instance-local-nvme", operator = "Gt", values = ["0"] },
            { key = "kubernetes.io/arch", operator = "In", values = ["amd64"] },
            { key = "kubernetes.io/os", operator = "In", values = ["linux"] },
          ]
          expireAfter = "Never"
        }
      }
      disruption = {
        # Reclaim the big-disk node as soon as the build Job is gone.
        consolidationPolicy = "WhenEmpty"
        consolidateAfter    = "1m"
      }
    }
  })

  depends_on = [
    kubectl_manifest.ec2nodeclass_image_builder,
    helm_release.karpenter,
    null_resource.wait_for_node_drain,
  ]
}

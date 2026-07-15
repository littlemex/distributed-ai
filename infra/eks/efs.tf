# efs.tf
# Shared, multi-AZ, ReadWriteMany EFS filesystem for the Neuron/HF compile caches used by
# accelerated serving apps (e.g. voice-image-edit expects /mnt/efs/neuron-workspace).
#
# Why EFS (not FSx Lustre) for this:
#   - Multi-AZ: mount targets in every private subnet, so a Pod on the trn2 Capacity-Block
#     AZ mounts the same cache as a Pod on any other AZ. FSx Lustre is single-AZ.
#   - ReadWriteMany: many model Pods share one NEFF/HF cache.
#   - Survives node loss: when Karpenter replaces a CB/Spot node, the rescheduled Pod
#     re-mounts the cache and skips the multi-ten-minute recompile.
# All resources are gated on var.efs_enabled.

# ---------------------------------------------------------------------------
# EFS CSI driver — IAM role for EKS Pod Identity (mirrors the EBS CSI pattern in iam.tf)
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "efs_csi_assume" {
  count = var.efs_enabled ? 1 : 0
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "efs_csi" {
  count              = var.efs_enabled ? 1 : 0
  name               = "${var.cluster_name}-efs-csi"
  assume_role_policy = data.aws_iam_policy_document.efs_csi_assume[0].json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "efs_csi" {
  count      = var.efs_enabled ? 1 : 0
  role       = aws_iam_role.efs_csi[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
}

# ---------------------------------------------------------------------------
# EFS filesystem + one mount target per private subnet (AZ-independent access)
# ---------------------------------------------------------------------------
resource "aws_efs_file_system" "shared" {
  count            = var.efs_enabled ? 1 : 0
  creation_token   = "${var.cluster_name}-shared"
  encrypted        = true
  performance_mode = "generalPurpose"
  throughput_mode  = "elastic" # scales with workload; no provisioned-throughput guesswork

  tags = {
    Name        = "${var.cluster_name}-efs-shared"
    Environment = var.environment
    Project     = "distributed-ai"
  }
}

resource "aws_security_group" "efs" {
  count       = var.efs_enabled ? 1 : 0
  name        = "${var.cluster_name}-efs-sg"
  description = "Allow NFS (2049) from EKS nodes to EFS"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "NFS 2049 from within the VPC (EKS nodes)"
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.cluster_name}-efs-sg"
    Environment = var.environment
  }
}

# One mount target per private subnet => reachable from every AZ the cluster spans.
resource "aws_efs_mount_target" "shared" {
  count           = var.efs_enabled ? length(module.vpc.private_subnets) : 0
  file_system_id  = aws_efs_file_system.shared[0].id
  subnet_id       = module.vpc.private_subnets[count.index]
  security_groups = [aws_security_group.efs[0].id]
}

# Access point rooted at the app's canonical workspace, owned by root (containers run as
# root here). The app symlinks /models, /mnt/local/compiled_models, and the HF cache under
# this path (EFS_ROOT=/mnt/efs/neuron-workspace).
resource "aws_efs_access_point" "neuron_workspace" {
  count          = var.efs_enabled ? 1 : 0
  file_system_id = aws_efs_file_system.shared[0].id

  posix_user {
    uid = 0
    gid = 0
  }
  root_directory {
    path = "/neuron-workspace"
    creation_info {
      owner_uid   = 0
      owner_gid   = 0
      permissions = "0755"
    }
  }
  tags = {
    Name        = "${var.cluster_name}-efs-neuron-workspace"
    Environment = var.environment
  }
}

# ---------------------------------------------------------------------------
# aws-efs-csi-driver EKS addon (Pod Identity for dynamic access-point provisioning)
# ---------------------------------------------------------------------------
resource "aws_eks_addon" "efs_csi_driver" {
  count         = var.efs_enabled ? 1 : 0
  cluster_name  = var.cluster_name
  addon_name    = "aws-efs-csi-driver"
  addon_version = var.efs_csi_driver_version

  pod_identity_association {
    role_arn        = aws_iam_role.efs_csi[0].arn
    service_account = "efs-csi-controller-sa"
  }

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = {
    Environment = var.environment
    Project     = "distributed-ai"
  }

  depends_on = [module.eks]
}

# ---------------------------------------------------------------------------
# Static PV/PVC for the app cache. Static (not dynamic) so the same filesystem +
# access point is reused across teardowns of the workload namespace.
# ---------------------------------------------------------------------------
resource "kubectl_manifest" "efs_storage_class" {
  count = var.efs_enabled ? 1 : 0
  yaml_body = yamlencode({
    apiVersion  = "storage.k8s.io/v1"
    kind        = "StorageClass"
    metadata    = { name = "efs-shared" }
    provisioner = "efs.csi.aws.com"
    parameters = {
      provisioningMode = "efs-ap"
      fileSystemId     = aws_efs_file_system.shared[0].id
      directoryPerms   = "0755"
    }
    reclaimPolicy     = "Retain"
    volumeBindingMode = "Immediate"
  })
  depends_on = [aws_eks_addon.efs_csi_driver]
}

resource "kubectl_manifest" "efs_neuron_workspace_pv" {
  count = var.efs_enabled ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "PersistentVolume"
    metadata   = { name = "efs-neuron-workspace" }
    spec = {
      capacity                      = { storage = "1000Gi" } # EFS is elastic; this is a nominal claim size
      volumeMode                    = "Filesystem"
      accessModes                   = ["ReadWriteMany"]
      persistentVolumeReclaimPolicy = "Retain"
      # Empty storageClassName marks this a statically-provisioned PV: a PVC must bind by
      # volumeName, and the dynamic "efs-shared" StorageClass provisioner never acts on it.
      # (Reusing "efs-shared" here would let the dynamic provisioner race this static PV.)
      storageClassName = ""
      csi = {
        driver       = "efs.csi.aws.com"
        volumeHandle = "${aws_efs_file_system.shared[0].id}::${aws_efs_access_point.neuron_workspace[0].id}"
      }
    }
  })
  depends_on = [kubectl_manifest.efs_storage_class]
}

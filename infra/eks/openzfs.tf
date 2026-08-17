# openzfs.tf
# FSx for OpenZFS — single-AZ NFS home/general-shared filesystem. This is the second layer of
# the default two-layer storage set (Lustre scratch in fsx.tf + OpenZFS NFS home here),
# mirroring awsome-distributed-ai. OpenZFS serves the many-small-files home/shared workload
# (code, configs, datasets, conda/venv) that would saturate Lustre's metadata
# path; Lustre stays the high-throughput scratch/checkpoint layer. ON by default
# (var.openzfs_enabled): the training samples mount /shared from here.
#
# CSI-driver DECOUPLING (same reasoning as fsx.tf/efs.tf): the aws-fsx-openzfs-csi-driver and
# its IAM role are created UNCONDITIONALLY. var.openzfs_enabled gates ONLY the filesystem, its
# security group, and the static PV.
#
# ASYMMETRY with Lustre/EFS: the OpenZFS CSI driver is NOT an EKS managed add-on (only
# aws-fsx-csi-driver — Lustre — and aws-efs-csi-driver are). So it is installed via a Helm
# release + a standalone Pod Identity association, exactly mirroring the ALB controller
# pattern in alb-controller.tf, rather than an aws_eks_addon with an inline
# pod_identity_association block.

# ---------------------------------------------------------------------------
# FSx for OpenZFS file system (SINGLE_AZ_1, non-HA) + one static PV.
# ---------------------------------------------------------------------------
resource "aws_fsx_openzfs_file_system" "shared" {
  count = var.openzfs_enabled ? 1 : 0
  # Single-AZ placement — pins to var.openzfs_subnet_index (default 0 = private_subnets[0]).
  # Access is over NFS; a pod in another AZ can still mount but pays cross-AZ transfer, so
  # keep this aligned with the accelerator pool that uses it (same intra-AZ reason as Lustre).
  subnet_ids         = [module.vpc.private_subnets[var.openzfs_subnet_index]]
  security_group_ids = [aws_security_group.openzfs[0].id]

  # SINGLE_AZ_1 = non-HA single-AZ. Its throughput ladder is the 64-based one validated in
  # variables.tf (64/128/256/...); SINGLE_AZ_2/Multi-AZ use a different (160-based) ladder.
  deployment_type     = "SINGLE_AZ_1"
  storage_capacity    = var.openzfs_storage_capacity_gib
  throughput_capacity = var.openzfs_throughput_capacity
  storage_type        = "SSD"

  root_volume_configuration {
    data_compression_type = "LZ4"
    # Export the root volume over NFS to any client in the VPC. no_root_squash so root-owned
    # container processes (the samples run as root) can write; crossmnt so child volumes are
    # traversable through the single mount. Matches awsome-distributed-ai's OpenZFS module.
    nfs_exports {
      client_configurations {
        clients = "*"
        options = ["rw", "no_root_squash", "crossmnt"]
      }
    }
  }

  tags = {
    Name        = "${var.cluster_name}-fsx-openzfs"
    Environment = var.environment
    Project     = "distributed-ai"
  }

  # NOTE: prevent_destroy intentionally omitted — same rationale as fsx.tf (reproducible
  # sample environment, regenerable data). Set prevent_destroy = true for irreplaceable data.
}

resource "aws_security_group" "openzfs" {
  count       = var.openzfs_enabled ? 1 : 0
  name        = "${var.cluster_name}-openzfs-sg"
  description = "Allow NFS (2049) from EKS nodes to the FSx OpenZFS file system"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "NFS 2049 from within the VPC (EKS nodes). NFSv4.1 needs only 2049 (no rpcbind)."
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
    Name        = "${var.cluster_name}-openzfs-sg"
    Environment = var.environment
  }
}

# ---------------------------------------------------------------------------
# IAM role for EKS Pod Identity — created UNCONDITIONALLY (permanent infra).
# For static provisioning the controller only reads filesystem/volume metadata
# (fsx:DescribeFileSystems / fsx:DescribeVolumes); the create/delete actions in the upstream
# example policy are dynamic-provisioning-only and never exercised by a fixed-volumeHandle PV.
# Describe* are account/region-wide list/discovery operations, so this stays Resource "*".
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "openzfs_csi_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "openzfs_csi" {
  name               = "${var.cluster_name}-openzfs-csi"
  assume_role_policy = data.aws_iam_policy_document.openzfs_csi_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "openzfs_csi_describe" {
  statement {
    actions = [
      "fsx:DescribeFileSystems",
      "fsx:DescribeVolumes",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "openzfs_csi_describe" {
  name   = "openzfs-describe"
  role   = aws_iam_role.openzfs_csi.id
  policy = data.aws_iam_policy_document.openzfs_csi_describe.json
}

# Optional DYNAMIC-provisioning permissions. Static (fixed-volumeHandle) PVs never need these;
# dynamic per-PVC child-volume provisioning (multi-tenant) requires create/delete. Gated by
# var.openzfs_dynamic_provisioning_enabled so the default footprint stays describe-only, and by
# var.openzfs_enabled so the policy never references a filesystem that does not exist.
#
# Scoped to child volumes of THIS filesystem: FSx supports the volume ARN
# (arn:...:volume/<fs-id>/<vol-id>), so DeleteVolume cannot reach volumes in any other filesystem.
# aws-fsx-openzfs-csi-driver only calls CreateVolume / DeleteVolume / DescribeVolumes (granted in
# the describe policy) / ListTagsForResource, and tags volumes on create; it never calls
# UntagResource or UpdateVolume. "fsx:CreateVolumeFromSnapshot" is not a real FSx IAM action
# (a snapshot-origin volume is created by CreateVolume with OriginSnapshot).
data "aws_iam_policy_document" "openzfs_csi_dynamic" {
  count = var.openzfs_enabled && var.openzfs_dynamic_provisioning_enabled ? 1 : 0
  statement {
    sid = "DynamicChildVolumes"
    actions = [
      "fsx:CreateVolume",
      "fsx:DeleteVolume",
      "fsx:TagResource",
      "fsx:ListTagsForResource",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:fsx:${var.region}:${data.aws_caller_identity.current.account_id}:volume/${aws_fsx_openzfs_file_system.shared[0].id}/*",
    ]
  }
}

resource "aws_iam_role_policy" "openzfs_csi_dynamic" {
  count  = var.openzfs_enabled && var.openzfs_dynamic_provisioning_enabled ? 1 : 0
  name   = "openzfs-dynamic-provisioning"
  role   = aws_iam_role.openzfs_csi.id
  policy = data.aws_iam_policy_document.openzfs_csi_dynamic[0].json
}

# ---------------------------------------------------------------------------
# Pod Identity association — binds the role to the controller SA the Helm chart creates.
# Created unconditionally (mirrors the ALB controller pattern in alb-controller.tf); EKS
# resolves it at pod startup, so it is safe to create before the SA exists.
# ---------------------------------------------------------------------------
resource "aws_eks_pod_identity_association" "openzfs_csi" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "fsx-openzfs-csi-controller-sa"
  role_arn        = aws_iam_role.openzfs_csi.arn
  tags            = var.tags
}

# ---------------------------------------------------------------------------
# aws-fsx-openzfs-csi-driver Helm release — installed unconditionally (permanent infra).
# NOT an EKS managed add-on, hence Helm (see file header). helm provider ~> 2.15 set{} syntax
# (versions.tf); migrate to a values map when upgrading to helm provider v3.
# ---------------------------------------------------------------------------
resource "helm_release" "openzfs_csi_driver" {
  name             = "aws-fsx-openzfs-csi-driver"
  repository       = "https://kubernetes-sigs.github.io/aws-fsx-openzfs-csi-driver"
  chart            = "aws-fsx-openzfs-csi-driver"
  version          = var.openzfs_csi_driver_chart_version
  namespace        = "kube-system"
  create_namespace = false # kube-system already exists
  wait             = true
  timeout          = 300

  # Let the chart create fsx-openzfs-csi-controller-sa; the Pod Identity association above
  # binds the IAM role to that SA name (same handshake as the ALB controller).
  set {
    name  = "controller.serviceAccount.create"
    value = "true"
  }

  set {
    name  = "controller.serviceAccount.name"
    value = "fsx-openzfs-csi-controller-sa"
  }

  depends_on = [
    module.eks,
    aws_iam_role_policy.openzfs_csi_describe,
    aws_eks_pod_identity_association.openzfs_csi,
  ]
}

# ---------------------------------------------------------------------------
# Static PV for the Terraform-managed OpenZFS filesystem (mirrors fsx_training_pv / EFS PV).
# No StorageClass: a PVC binds directly by volumeName. NFS mount options per the driver's
# static-provisioning example. volumeAttributes keys are CamelCase here (DNSName/ResourceType)
# — the OPPOSITE of the Lustre driver's lowercase dnsname/mountname (a per-driver quirk; the
# OpenZFS driver reads CamelCase and a lowercase key is silently ignored).
# ---------------------------------------------------------------------------
resource "kubectl_manifest" "openzfs_shared_pv" {
  count = var.openzfs_enabled ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "PersistentVolume"
    metadata   = { name = "openzfs-shared" }
    spec = {
      capacity                      = { storage = "${var.openzfs_storage_capacity_gib}Gi" }
      volumeMode                    = "Filesystem"
      accessModes                   = ["ReadWriteMany"]
      persistentVolumeReclaimPolicy = "Retain"
      # Empty storageClassName marks this a statically-provisioned PV — see the analogous note
      # in fsx.tf/efs.tf for why this must not reference a dynamic StorageClass name.
      storageClassName = ""
      mountOptions = [
        "nfsvers=4.1",
        "rsize=1048576",
        "wsize=1048576",
        "timeo=600",
      ]
      csi = {
        driver = "fsx.openzfs.csi.aws.com"
        # volumeHandle is the bare filesystem id (fs-xxx), NOT the "<fsid>::<apid>" form the
        # EFS driver uses. The controller resolves the DNS name from volumeAttributes below.
        volumeHandle = aws_fsx_openzfs_file_system.shared[0].id
        volumeAttributes = {
          DNSName      = aws_fsx_openzfs_file_system.shared[0].dns_name
          ResourceType = "filesystem"
        }
      }
    }
  })

  depends_on = [helm_release.openzfs_csi_driver]
}

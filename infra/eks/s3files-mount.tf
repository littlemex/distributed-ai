################################################################################
# S3 Files mount for analysis-mcp (gated). Mounts the trace bucket's S3 Files file
# system (created in infra/data-layer) into the cluster so the analysis-mcp pod reads
# GB profiler artifacts IN PLACE (no download). The file system + access point live in
# data-layer; here we create the in-VPC mount target + the S3 Files IAM the EFS CSI
# driver needs. The static CSI PersistentVolume is rendered by charts/analysis-mcp
# (volumeHandle = data-layer's s3files_volume_handle output).
#
# S3 Files on EKS uses the Amazon EFS CSI driver (S3 Files support >= v3.0.0), already
# managed in efs.tf. The gotchas this encodes (verified on a live cluster):
#   - the PV volumeHandle MUST be "s3files:<fs>::<ap>" (a bare fs-id takes the EFS path
#     and the mount fails) — handled by the chart from the data-layer output;
#   - the mount runs on the NODE plugin (efs-csi-node-sa). Without a Pod Identity for
#     that SA it falls back to the node instance role, and a Karpenter + managed-nodegroup
#     cluster has more than one node role — grant only one and pods on the other get
#     `mount.nfs4: access denied by server`. So we associate efs-csi-node-sa explicitly.
#
# There is no aws_s3files_* resource yet, but AWS::S3Files::MountTarget is a Cloud Control
# type, so the mount target is managed declaratively via aws_cloudcontrolapi_resource.
#
# CROSS-STATE DESTROY ORDER (must): tear down infra/eks BEFORE infra/data-layer. This stack's
# mount target must be gone before data-layer destroys the S3 Files file system — an EFS-backed fs
# cannot be deleted while a mount target exists, so a data-layer-first destroy deletes the access
# point (instant I/O outage on live pods), then FAILS on the fs, leaving a half-torn-down,
# service-down state. The dependency cannot be expressed in Terraform (this state only holds the
# fs id as a plain var), so it is enforced operationally (teardown runbook), not by code.
################################################################################

variable "s3files_enabled" {
  description = "Create the in-VPC S3 Files mount target + the S3 Files IAM for the EFS CSI driver, so analysis-mcp can mount the trace bucket. Default OFF. Requires the data-layer S3 Files file system (pass its id below). The file_system_id-required check is a precondition on the mount target (not a variable validation), so this stack still validates under Terraform < 1.9 — matching the data-layer's choice (R4)."
  type        = bool
  default     = false
}

variable "s3files_file_system_id" {
  description = "S3 Files file system id from infra/data-layer (`terraform output -raw s3files_file_system_id`). Required when s3files_enabled."
  type        = string
  default     = ""
}

variable "s3files_subnet_index" {
  description = "Index into module.vpc.private_subnets for the S3 Files mount target (single-AZ, like fsx_subnet_index). The mount is reachable only from this AZ, so charts pin their pods to it via the PV nodeAffinity (s3files_mount_target_az output). Add more mount targets for multi-AZ."
  type        = number
  default     = 0
}

locals {
  # The CSI plugin authorizes the NFS mount with THIS role's credential (not the pod's). Per the S3
  # Files docs, s3files:ClientMount WITHOUT s3files:ClientWrite yields a READ-ONLY mount, enforced
  # on every mount — this is exactly the AWS managed AmazonS3FilesClientReadOnlyAccess vs
  # ...ClientFullAccess split ("ClientWrite ... not required for read-only connections"). Unlike
  # EFS, S3 Files has NO file-system-policy resource (AWS::S3Files::FileSystem exposes no policy
  # property), so the client IAM action IS the enforcement; there is nothing else to attach.
  # Because this node-plugin role authorizes ALL S3 Files mounts on the cluster, no pod can obtain a
  # RW mount regardless of its PV — that is what keeps the "only the janitor deletes" invariant from
  # being bypassed via the NFS path. Deliberately NO ClientWrite/ClientRootAccess.
  #
  # Also deliberately NO s3:GetObject/KMS: the docs list a direct-S3-read inline policy only as an
  # optional READ-PERFORMANCE optimization (read-only; no Delete, so it does not re-open the
  # invariant). Omitted for least privilege; add s3:GetObject/GetObjectVersion/ListBucket (+
  # kms:Decrypt for SSE-KMS) on the node role only if read-throughput measurements justify it.
  # Controller and node share this one minimal read-only policy.
  s3files_client_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "S3FilesClientMountReadOnly"
      Effect = "Allow"
      Action = ["s3files:ClientMount",
        "s3files:DescribeMountTargets", "s3files:DescribeFileSystems",
      "s3files:DescribeAccessPoints", "s3files:GetAccessPoint", "s3files:ListAccessPoints"]
      Resource = "*"
    }]
  })
}

# --- mount target SG: NFS 2049 from the cluster nodes -----------------------------------------
resource "aws_security_group" "s3files_mt" {
  count       = var.s3files_enabled ? 1 : 0
  name        = "${var.cluster_name}-s3files-mt"
  description = "S3 Files mount target: NFS 2049 from EKS nodes"
  vpc_id      = module.vpc.vpc_id
  tags        = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "s3files_mt_from_nodes" {
  count                        = var.s3files_enabled ? 1 : 0
  security_group_id            = aws_security_group.s3files_mt[0].id
  ip_protocol                  = "tcp"
  from_port                    = 2049
  to_port                      = 2049
  referenced_security_group_id = module.eks.node_security_group_id
}

# --- the mount target (Cloud Control) ---------------------------------------------------------
resource "aws_cloudcontrolapi_resource" "s3files_mt" {
  count     = var.s3files_enabled ? 1 : 0
  type_name = "AWS::S3Files::MountTarget"
  desired_state = jsonencode({
    FileSystemId   = var.s3files_file_system_id
    SubnetId       = module.vpc.private_subnets[var.s3files_subnet_index]
    SecurityGroups = [aws_security_group.s3files_mt[0].id]
  })

  lifecycle {
    precondition {
      condition     = var.s3files_file_system_id != ""
      error_message = "s3files_enabled=true but s3files_file_system_id is empty — set it to infra/data-layer's s3files_file_system_id output. (precondition, not a variable validation, so this stack validates under Terraform < 1.9 — R4.)"
    }
  }
}

# --- S3 Files IAM for the EFS CSI driver ------------------------------------------------------
# Controller role (aws_iam_role.efs_csi in efs.tf) gets S3 Files client perms in addition to its
# EFS policy.
resource "aws_iam_role_policy" "efs_csi_s3files" {
  count  = var.s3files_enabled ? 1 : 0
  name   = "s3files-client"
  role   = aws_iam_role.efs_csi.id
  policy = local.s3files_client_policy
}

# Node plugin: its own role + Pod Identity for efs-csi-node-sa (do NOT rely on the node instance
# role — multi-nodegroup/Karpenter clusters have more than one, and the mount fails on the ones
# without the grant).
data "aws_iam_policy_document" "efs_csi_node_assume" {
  count = var.s3files_enabled ? 1 : 0
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "efs_csi_node" {
  count              = var.s3files_enabled ? 1 : 0
  name               = "${var.cluster_name}-efs-csi-node-s3files"
  assume_role_policy = data.aws_iam_policy_document.efs_csi_node_assume[0].json
  tags               = var.tags
}

resource "aws_iam_role_policy" "efs_csi_node_s3files" {
  count  = var.s3files_enabled ? 1 : 0
  name   = "s3files-client"
  role   = aws_iam_role.efs_csi_node[0].id
  policy = local.s3files_client_policy
}

# Pod Identity replaces the SA's credential for ALL its AWS calls, so once efs-csi-node-sa is
# associated with this role, the node plugin no longer uses the node instance role for its EXISTING
# EFS work either. Without the EFS CSI managed policy here, enabling S3 Files (and restarting the
# DaemonSet) would break every current EFS mount with `access denied` (N1). Carry both.
resource "aws_iam_role_policy_attachment" "efs_csi_node_efs" {
  count      = var.s3files_enabled ? 1 : 0
  role       = aws_iam_role.efs_csi_node[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
}

resource "aws_eks_pod_identity_association" "efs_csi_node" {
  count           = var.s3files_enabled ? 1 : 0
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "efs-csi-node-sa"
  role_arn        = aws_iam_role.efs_csi_node[0].arn
}

# ENABLE-DAY STEP (R3, not enforceable in pure TF): EKS Pod Identity credentials are injected by a
# mutating webhook at POD CREATE time, so the efs-csi-node DaemonSet pods already running when this
# association is created keep using the node INSTANCE role until restarted — and mount as
# `access denied by server` on those nodes. After the first `apply` that flips s3files_enabled=true,
# run:  kubectl rollout restart ds/efs-csi-node -n kube-system
# New (Karpenter) nodes pick up the credential automatically; only pre-existing nodes need this.

output "s3files_mount_target_ip" {
  description = "S3 Files mount target IPv4 (null when s3files_enabled=false)."
  value       = var.s3files_enabled ? jsondecode(aws_cloudcontrolapi_resource.s3files_mt[0].properties).Ipv4Address : null
}

data "aws_subnet" "s3files_mt" {
  count = var.s3files_enabled ? 1 : 0
  id    = module.vpc.private_subnets[var.s3files_subnet_index]
}

output "s3files_mount_target_az" {
  description = "Availability zone of the single S3 Files mount target. The mount is reachable ONLY from this AZ (NFS DNS resolves per-AZ), so pass it to charts as s3files.zone to pin the PV nodeAffinity — otherwise a pod scheduled in another AZ hangs in ContainerCreating (lifecycle B3). null when disabled."
  # Read the SUBNET's real AZ, not azs[subnet_index] — the private_subnets<->azs index mapping is
  # not 1:1 when there is more than one private subnet per AZ, and a wrong AZ here would pin every
  # pod to an AZ the mount can't reach (the worst form of B3).
  value = var.s3files_enabled ? data.aws_subnet.s3files_mt[0].availability_zone : null
}

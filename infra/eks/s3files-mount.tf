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
################################################################################

variable "s3files_enabled" {
  description = "Create the in-VPC S3 Files mount target + the S3 Files IAM for the EFS CSI driver, so analysis-mcp can mount the trace bucket. Default OFF. Requires the data-layer S3 Files file system (pass its id/bucket/kms below)."
  type        = bool
  default     = false

  validation {
    condition     = var.s3files_enabled == false || var.s3files_file_system_id != ""
    error_message = "s3files_enabled is true but s3files_file_system_id is empty — set it to infra/data-layer's s3files_file_system_id output."
  }
}

variable "s3files_file_system_id" {
  description = "S3 Files file system id from infra/data-layer (`terraform output -raw s3files_file_system_id`). Required when s3files_enabled."
  type        = string
  default     = ""
}

variable "s3files_trace_bucket_arn" {
  description = "ARN of the trace bucket the S3 Files fs is over (for the node's direct-read policy). Required when s3files_enabled."
  type        = string
  default     = ""
}

variable "s3files_kms_key_arn" {
  description = "KMS CMK ARN encrypting the trace bucket (SSE-KMS). Empty => no KMS statement (SSE-S3 bucket)."
  type        = string
  default     = ""
}

variable "s3files_subnet_index" {
  description = "Index into module.vpc.private_subnets for the S3 Files mount target (single-AZ, like fsx_subnet_index). Pods reading the mount should run in this AZ; add more mount targets for multi-AZ."
  type        = number
  default     = 0
}

locals {
  # s3files:ClientMount/ClientWrite/ClientRootAccess + Describe*, scoped to the account's S3 Files.
  s3files_client_statements = [
    {
      Sid      = "S3FilesClient"
      Effect   = "Allow"
      Action   = ["s3files:ClientMount", "s3files:ClientWrite", "s3files:ClientRootAccess",
                  "s3files:DescribeMountTargets", "s3files:DescribeFileSystems",
                  "s3files:DescribeAccessPoints", "s3files:GetAccessPoint", "s3files:ListAccessPoints"]
      Resource = "*"
    },
    {
      Sid      = "S3DirectRead"
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:GetObjectVersion", "s3:ListBucket"]
      Resource = [var.s3files_trace_bucket_arn, "${var.s3files_trace_bucket_arn}/*"]
    },
  ]
  s3files_kms_statement = var.s3files_kms_key_arn == "" ? [] : [{
    Sid      = "KmsRead"
    Effect   = "Allow"
    Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
    Resource = [var.s3files_kms_key_arn]
  }]
  s3files_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = concat(local.s3files_client_statements, local.s3files_kms_statement)
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
}

# --- S3 Files IAM for the EFS CSI driver ------------------------------------------------------
# Controller role (aws_iam_role.efs_csi in efs.tf) gets S3 Files client perms in addition to its
# EFS policy.
resource "aws_iam_role_policy" "efs_csi_s3files" {
  count  = var.s3files_enabled ? 1 : 0
  name   = "s3files-client"
  role   = aws_iam_role.efs_csi.id
  policy = local.s3files_policy
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
  policy = local.s3files_policy
}

resource "aws_eks_pod_identity_association" "efs_csi_node" {
  count           = var.s3files_enabled ? 1 : 0
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "efs-csi-node-sa"
  role_arn        = aws_iam_role.efs_csi_node[0].arn
}

output "s3files_mount_target_ip" {
  description = "S3 Files mount target IPv4 (null when s3files_enabled=false)."
  value       = var.s3files_enabled ? jsondecode(aws_cloudcontrolapi_resource.s3files_mt[0].properties).Ipv4Address : null
}

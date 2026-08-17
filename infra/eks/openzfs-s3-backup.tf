################################################################################
# Periodic FSx for OpenZFS -> S3 cold-data offload.
#
# FSx for OpenZFS has no S3-native integration like Lustre's DRA, so cold data is pushed with
# `aws s3 sync` from a Pod that mounts the volume. This file wires that up as a scheduled CronJob
# together with everything it needs, so the whole thing is one self-consistent Terraform toggle
# (no CLI-created bucket that Terraform cannot see): the backup bucket, the CronJob's ServiceAccount,
# a Pod Identity association to an IAM role scoped to that bucket, and the CronJob itself.
#
# Gated on var.enable_fsx_openzfs_s3_backup AND var.openzfs_enabled (never reference a filesystem or
# PVC that does not exist). Toggling OFF removes the CronJob/SA/association. The bucket is the source
# of truth (force_destroy = false), so toggle-off/destroy fails loudly if it still holds objects —
# empty it deliberately first; backup data is never silently deleted.
################################################################################

locals {
  openzfs_s3_backup_on  = var.openzfs_enabled && var.enable_fsx_openzfs_s3_backup
  openzfs_backup_bucket = "${var.cluster_name}-openzfs-cold-${data.aws_caller_identity.current.account_id}"
  openzfs_backup_sa     = "fsx-openzfs-s3-backup"
  openzfs_backup_image  = "public.ecr.aws/aws-cli/aws-cli:latest"
}

# The cold-data bucket is the "source of truth" for offloaded data, so force_destroy is FALSE:
# turning the backup toggle off (or destroy) will NOT silently delete retained objects — the
# apply/destroy fails loudly if the bucket still holds data, and you must empty it deliberately
# first. This is intentional (protects backups), unlike a scratch bucket.
resource "aws_s3_bucket" "openzfs_cold" {
  count         = local.openzfs_s3_backup_on ? 1 : 0
  bucket        = local.openzfs_backup_bucket
  force_destroy = false
  tags          = var.tags
}

resource "aws_s3_bucket_public_access_block" "openzfs_cold" {
  count                   = local.openzfs_s3_backup_on ? 1 : 0
  bucket                  = aws_s3_bucket.openzfs_cold[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "openzfs_cold" {
  count  = local.openzfs_s3_backup_on ? 1 : 0
  bucket = aws_s3_bucket.openzfs_cold[0].id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_versioning" "openzfs_cold" {
  count  = local.openzfs_s3_backup_on ? 1 : 0
  bucket = aws_s3_bucket.openzfs_cold[0].id
  versioning_configuration { status = "Enabled" }
}

data "aws_iam_policy_document" "openzfs_backup_assume" {
  count = local.openzfs_s3_backup_on ? 1 : 0
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "openzfs_backup" {
  count              = local.openzfs_s3_backup_on ? 1 : 0
  name               = "${var.cluster_name}-openzfs-s3-backup"
  assume_role_policy = data.aws_iam_policy_document.openzfs_backup_assume[0].json
  tags               = var.tags
}

# Scoped to the backup prefix, no delete: PutObject to upload, GetObject + prefix-conditioned
# ListBucket for `aws s3 sync` diffing. A compromised job cannot enumerate or read other prefixes
# of the bucket, and cannot delete anything.
data "aws_iam_policy_document" "openzfs_backup" {
  count = local.openzfs_s3_backup_on ? 1 : 0
  statement {
    sid       = "ListBackupPrefix"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.openzfs_cold[0].arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${var.openzfs_s3_backup_prefix}*"]
    }
  }
  statement {
    sid       = "WriteBackupObjects"
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = ["${aws_s3_bucket.openzfs_cold[0].arn}/${var.openzfs_s3_backup_prefix}*"]
  }
}

resource "aws_iam_role_policy" "openzfs_backup" {
  count  = local.openzfs_s3_backup_on ? 1 : 0
  name   = "openzfs-s3-backup"
  role   = aws_iam_role.openzfs_backup[0].id
  policy = data.aws_iam_policy_document.openzfs_backup[0].json
}

resource "kubectl_manifest" "openzfs_backup_sa" {
  count = local.openzfs_s3_backup_on ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ServiceAccount"
    metadata   = { name = local.openzfs_backup_sa, namespace = var.openzfs_s3_backup_namespace }
  })
}

resource "aws_eks_pod_identity_association" "openzfs_backup" {
  count           = local.openzfs_s3_backup_on ? 1 : 0
  cluster_name    = module.eks.cluster_name
  namespace       = var.openzfs_s3_backup_namespace
  service_account = local.openzfs_backup_sa
  role_arn        = aws_iam_role.openzfs_backup[0].arn
  depends_on      = [kubectl_manifest.openzfs_backup_sa]
}

resource "kubectl_manifest" "openzfs_backup_cronjob" {
  count = local.openzfs_s3_backup_on ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "batch/v1"
    kind       = "CronJob"
    metadata   = { name = "fsx-openzfs-s3-sync", namespace = var.openzfs_s3_backup_namespace }
    spec = {
      schedule                   = var.openzfs_s3_backup_schedule
      concurrencyPolicy          = "Forbid"
      successfulJobsHistoryLimit = 1
      failedJobsHistoryLimit     = 1
      jobTemplate = {
        spec = {
          backoffLimit = 2
          template = {
            spec = {
              serviceAccountName = local.openzfs_backup_sa
              restartPolicy      = "Never"
              securityContext    = { runAsNonRoot = true, runAsUser = 1000, fsGroup = 1000, seccompProfile = { type = "RuntimeDefault" } }
              containers = [{
                name    = "sync"
                image   = local.openzfs_backup_image
                command = ["aws", "s3", "sync", "/shared", "s3://${local.openzfs_backup_bucket}/${var.openzfs_s3_backup_prefix}"]
                env     = [{ name = "HOME", value = "/tmp" }, { name = "AWS_REGION", value = var.region }]
                securityContext = {
                  allowPrivilegeEscalation = false
                  readOnlyRootFilesystem   = true
                  capabilities             = { drop = ["ALL"] }
                }
                resources = { requests = { cpu = "100m", memory = "128Mi" }, limits = { memory = "512Mi" } }
                volumeMounts = [
                  { name = "vol", mountPath = "/shared", readOnly = true },
                  { name = "tmp", mountPath = "/tmp" },
                ]
              }]
              volumes = [
                { name = "vol", persistentVolumeClaim = { claimName = var.openzfs_s3_backup_pvc } },
                { name = "tmp", emptyDir = {} },
              ]
            }
          }
        }
      }
    }
  })
  depends_on = [aws_eks_pod_identity_association.openzfs_backup]
}

output "openzfs_s3_backup_bucket" {
  description = "S3 bucket the OpenZFS cold-data CronJob syncs to (null when disabled)."
  value       = local.openzfs_s3_backup_on ? aws_s3_bucket.openzfs_cold[0].bucket : null
}

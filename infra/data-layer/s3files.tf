# S3 Files (gated) — mount the trace bucket as a POSIX filesystem so consumer Pods read GB
# profiler artifacts (NEFF, nsys/ncu traces) IN PLACE instead of downloading them. S3 Files is
# an Amazon EFS-backed shared filesystem linked to an S3 bucket; the EKS side (mount target, CSI
# PV, IAM) lives in infra/eks (it needs the cluster VPC), and consumes the outputs here.
#
# There is no first-class aws_s3files_* Terraform resource yet, but AWS::S3Files::* IS registered
# with CloudFormation/Cloud Control, so we manage the file system + access point declaratively via
# aws_cloudcontrolapi_resource (real state/drift — not a null_resource+CLI shim).
#
# Gated OFF by default: S3 Files is EFS-backed and billed for the active-set high-performance
# storage, so it is opt-in per campaign, like the MLflow App.

variable "s3files_enabled" {
  description = <<-EOT
    Create an S3 Files file system + access point over the (central-region) trace bucket so
    consumer Pods can mount it. EFS-backed and billed for the resident active set, so default OFF.
    The trace bucket already has versioning + SSE-KMS (S3 Files requires both). The EKS mount
    target/PV/IAM are enabled separately in infra/eks (var.s3files_enabled there), consuming this
    module's s3files_volume_handle output.
  EOT
  type        = bool
  default     = false
}

variable "s3files_trace_region" {
  description = "Which trace bucket (by region key) to expose via S3 Files. Must be a key of var.trace_regions and should match the region this data-layer state runs in (mount targets are regional)."
  type        = string
  default     = "ap-northeast-1"
}

locals {
  s3files_bucket = var.s3files_enabled ? aws_s3_bucket.traces[var.s3files_trace_region].bucket : ""
}

# --- IAM role S3 Files assumes to sync with the bucket (per AWS S3 Files prereqs) --------------
data "aws_iam_policy_document" "s3files_assume" {
  count = var.s3files_enabled ? 1 : 0
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["elasticfilesystem.amazonaws.com"] # S3 Files is EFS-backed
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:s3files:${var.region}:${data.aws_caller_identity.current.account_id}:file-system/*"]
    }
  }
}

resource "aws_iam_role" "s3files" {
  count              = var.s3files_enabled ? 1 : 0
  name               = "${var.name_prefix}-s3files"
  assume_role_policy = data.aws_iam_policy_document.s3files_assume[0].json
  tags               = var.tags
}

resource "aws_iam_role_policy" "s3files" {
  count = var.s3files_enabled ? 1 : 0
  name  = "bucket-sync"
  role  = aws_iam_role.s3files[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "S3BucketPermissions"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:ListBucketVersions"]
        Resource = aws_s3_bucket.traces[var.s3files_trace_region].arn
      },
      {
        Sid      = "S3ObjectPermissions"
        Effect   = "Allow"
        Action   = ["s3:AbortMultipartUpload", "s3:DeleteObject*", "s3:GetObject*", "s3:List*", "s3:PutObject*"]
        Resource = "${aws_s3_bucket.traces[var.s3files_trace_region].arn}/*"
      },
      {
        Sid    = "UseKmsKeyWithS3Files"
        Effect = "Allow"
        Action = ["kms:GenerateDataKey", "kms:Encrypt", "kms:Decrypt", "kms:ReEncryptFrom", "kms:ReEncryptTo"]
        Condition = {
          StringLike = {
            "kms:ViaService" = "s3.${var.region}.amazonaws.com"
            "kms:EncryptionContext:aws:s3:arn" = [
              aws_s3_bucket.traces[var.s3files_trace_region].arn,
              "${aws_s3_bucket.traces[var.s3files_trace_region].arn}/*",
            ]
          }
        }
        Resource = aws_kms_key.data.arn
      },
      {
        Sid       = "EventBridgeManage"
        Effect    = "Allow"
        Action    = ["events:DeleteRule", "events:DisableRule", "events:EnableRule", "events:PutRule", "events:PutTargets", "events:RemoveTargets"]
        Condition = { StringEquals = { "events:ManagedBy" = "elasticfilesystem.amazonaws.com" } }
        Resource  = ["arn:aws:events:*:*:rule/DO-NOT-DELETE-S3-Files*"]
      },
      {
        Sid      = "EventBridgeRead"
        Effect   = "Allow"
        Action   = ["events:DescribeRule", "events:ListRuleNamesByTarget", "events:ListRules", "events:ListTargetsByRule"]
        Resource = ["arn:aws:events:*:*:rule/*"]
      },
    ]
  })
}

# --- The S3 Files file system + access point (via Cloud Control) -------------------------------
resource "aws_cloudcontrolapi_resource" "s3files_fs" {
  count     = var.s3files_enabled ? 1 : 0
  type_name = "AWS::S3Files::FileSystem"
  desired_state = jsonencode({
    Bucket              = aws_s3_bucket.traces[var.s3files_trace_region].arn
    RoleArn             = aws_iam_role.s3files[0].arn
    KmsKeyId            = aws_kms_key.data.arn
    AcceptBucketWarning = true
    Tags                = [for k, v in var.tags : { Key = k, Value = v }]
  })
  depends_on = [aws_iam_role_policy.s3files]

  # Guard the "magic region" default: s3files_trace_region must name a real trace bucket AND match
  # this data-layer's region — a mismatch would silently build a cross-region S3 Files fs whose
  # regional mount target (infra/eks) can't reach it. (precondition, not a cross-variable
  # validation block, so no Terraform >= 1.9 requirement — see M10.)
  lifecycle {
    precondition {
      condition     = contains(var.trace_regions, var.s3files_trace_region)
      error_message = "s3files_trace_region (${var.s3files_trace_region}) must be one of trace_regions (${join(", ", var.trace_regions)})."
    }
    precondition {
      condition     = var.s3files_trace_region == var.region
      error_message = "s3files_trace_region (${var.s3files_trace_region}) must match this data-layer's region (${var.region}); S3 Files mount targets are regional."
    }
  }
}

resource "aws_cloudcontrolapi_resource" "s3files_ap" {
  count     = var.s3files_enabled ? 1 : 0
  type_name = "AWS::S3Files::AccessPoint"
  desired_state = jsonencode({
    FileSystemId  = jsondecode(aws_cloudcontrolapi_resource.s3files_fs[0].properties).FileSystemId
    RootDirectory = { Path = "/" }
    Tags          = [for k, v in var.tags : { Key = k, Value = v }]
  })
}

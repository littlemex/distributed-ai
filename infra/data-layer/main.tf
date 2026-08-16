data "aws_caller_identity" "current" {}

locals {
  account_id       = data.aws_caller_identity.current.account_id
  artifacts_bucket = "${var.name_prefix}-mlflow-artifacts-${local.account_id}"
  trace_bucket     = { for r in var.trace_regions : r => "${var.name_prefix}-traces-${r}-${local.account_id}" }
}

# --- KMS CMK for artifact + trace encryption ---------------------------------------------------
# multi_region so that when per-region trace buckets become genuinely in-region (provider
# aliases), a same-region replica key can encrypt them without a rename/migration (the earlier
# single-region key would have made the "just add a provider alias" claim false).
resource "aws_kms_key" "data" {
  description             = "SSE-KMS for profiling traces and MLflow artifacts"
  enable_key_rotation     = true
  deletion_window_in_days = 14
  multi_region            = true
  tags                    = var.tags
}

resource "aws_kms_alias" "data" {
  name          = "alias/${var.name_prefix}-data-layer"
  target_key_id = aws_kms_key.data.key_id
}

# --- MLflow artifact store bucket (central; small artifacts only, GB traces go to trace buckets)
resource "aws_s3_bucket" "mlflow_artifacts" {
  bucket = local.artifacts_bucket
  tags   = var.tags
  lifecycle {
    prevent_destroy = true # record of record — never destroyed by a flag
  }
}

resource "aws_s3_bucket_versioning" "mlflow_artifacts" {
  bucket = aws_s3_bucket.mlflow_artifacts.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "mlflow_artifacts" {
  bucket = aws_s3_bucket.mlflow_artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.data.arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "mlflow_artifacts" {
  bucket                  = aws_s3_bucket.mlflow_artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- Per-region GB-trace buckets (traces stay in their accelerator's region) -------------------
# NOTE: buckets are created in var.region for this single-provider Phase-1 module; expanding to
# genuinely in-region buckets uses provider aliases per region (documented in README). The names
# and layout are region-keyed now so that expansion is a provider-alias change, not a rename.
resource "aws_s3_bucket" "traces" {
  for_each = local.trace_bucket
  bucket   = each.value
  tags     = merge(var.tags, { trace_region = each.key })
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "traces" {
  for_each = aws_s3_bucket.traces
  bucket   = each.value.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "traces" {
  for_each = aws_s3_bucket.traces
  bucket   = each.value.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.data.arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "traces" {
  for_each                = aws_s3_bucket.traces
  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "traces" {
  # Lifecycle must be decided at creation — it cannot be added retroactively without a data risk.
  for_each = aws_s3_bucket.traces
  bucket   = each.value.id

  rule {
    id     = "trace-tiering"
    status = "Enabled"
    filter {} # match all objects (required by recent provider versions)

    dynamic "transition" {
      for_each = var.trace_glacier_after_days > 0 ? [1] : []
      content {
        days          = var.trace_glacier_after_days
        storage_class = "GLACIER_IR"
      }
    }

    dynamic "expiration" {
      for_each = var.trace_expire_after_days > 0 ? [1] : []
      content {
        days = var.trace_expire_after_days
      }
    }

    # Versioning is on, so a plain expiration only adds a delete marker — noncurrent versions of
    # a GB trace would be billed forever. Expire noncurrent versions and abort orphaned multipart
    # uploads (a failed GB upload otherwise leaves billed parts).
    noncurrent_version_expiration {
      noncurrent_days = 7
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

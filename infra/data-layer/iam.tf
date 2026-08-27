# IAM: the MLflow App's artifact-access role, and the least-privilege roles that EKS Pod Identity
# maps the fixed `producer` / `mcp-reader` service accounts to. Trust is via EKS Pod Identity
# (pods.eks.amazonaws.com), so no per-namespace OIDC trust juggling.

data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

# --- MLflow data plane: one statement per role, written once for both backends -------------------
# Two axes, not six cases: the backend decides the action vocabulary, the role decides what it may do.
#
# A tracking server exposes granular sagemaker-mlflow:* actions, so a policy can say "log, never
# delete" and a reader can be genuinely read-only. An app exposes exactly one action,
# sagemaker:CallMlflowAppApi, covering its whole REST API — so on that backend the three roles below
# collapse to the same grant, and anything that can read MLflow can also delete from it. The reader
# accepts that (it cannot resolve a run without reading MLflow); the janitor does not get it, because a
# component whose job is deletion, holding delete on metadata that no versioning can restore, is the
# one combination worth refusing. What that costs is in the janitor's own comment below.
#
# Nothing here is ever scoped to a wildcard. The MLflow this layer creates is known by ARN, and an
# external tracking server is named by var.mlflow_tracking_server_arn; with neither, the role simply
# carries no MLflow statement rather than account-wide access it would silently acquire when a data
# layer is torn down.
locals {
  # The ARN follows the backend rather than outranking it. An external tracking server can only be named
  # on the "server" backend, because the action vocabulary below is chosen by the backend too: allowing
  # the app's single action against a tracking server ARN would compile cleanly and then 403 on every
  # call. coalesce raises when every argument is empty, which is exactly the "no MLflow anywhere" case.
  mlflow_policy_arn = var.mlflow_backend == "app" ? local.mlflow_arn : try(coalesce(var.mlflow_tracking_server_arn, local.mlflow_arn), "")

  mlflow_actions = var.mlflow_backend == "app" ? {
    reader   = ["sagemaker:CallMlflowAppApi", "sagemaker:CreatePresignedMlflowAppUrl"]
    lookup   = []
    producer = ["sagemaker:CallMlflowAppApi"]
    } : {
    reader = [
      "sagemaker-mlflow:AccessUI",
      "sagemaker-mlflow:GetExperiment",
      "sagemaker-mlflow:GetRun",
      "sagemaker-mlflow:SearchRuns",
      "sagemaker-mlflow:SearchExperiments",
      "sagemaker-mlflow:ListArtifacts",
      "sagemaker:CreatePresignedMlflowTrackingServerUrl",
    ]
    lookup = [
      "sagemaker-mlflow:GetExperiment",
      "sagemaker-mlflow:GetRun",
      "sagemaker-mlflow:SearchRuns",
    ]
    # Write-only. Deliberately NO Delete* — the run history is a record of record; a compromised
    # producer must not be able to erase experiments.
    producer = [
      "sagemaker-mlflow:CreateExperiment",
      "sagemaker-mlflow:GetExperimentByName",
      "sagemaker-mlflow:GetExperiment",
      "sagemaker-mlflow:CreateRun",
      "sagemaker-mlflow:GetRun",
      "sagemaker-mlflow:UpdateRun",
      "sagemaker-mlflow:LogMetric",
      "sagemaker-mlflow:LogParam",
      "sagemaker-mlflow:LogBatch",
      "sagemaker-mlflow:SetTag",
      "sagemaker-mlflow:SearchRuns",
      "sagemaker-mlflow:LogModel",
    ]
  }

  # A role with no actions on this backend, or a layer with no MLflow to name, contributes no
  # statement at all. Each is a list so the policies below can concat it away to nothing.
  mlflow_statements = { for role, actions in local.mlflow_actions :
    role => local.mlflow_policy_arn == "" || length(actions) == 0 ? [] : [{
      Effect   = "Allow"
      Action   = actions
      Resource = [local.mlflow_policy_arn]
    }]
  }
}

data "aws_iam_policy_document" "mlflow_app_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["sagemaker.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "mlflow_app" {
  name               = "${var.name_prefix}-mlflow-app"
  assume_role_policy = data.aws_iam_policy_document.mlflow_app_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "mlflow_app" {
  name = "artifact-access"
  role = aws_iam_role.mlflow_app.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.mlflow_artifacts.arn, "${aws_s3_bucket.mlflow_artifacts.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [aws_kms_key.data.arn]
      },
    ]
  })
}

# --- producer role: write traces (our S3), log MLflow runs, small artifacts --------------------
resource "aws_iam_role" "producer" {
  name               = "${var.name_prefix}-producer"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "producer" {
  name = "producer-access"
  role = aws_iam_role.producer.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        # PutObject to upload; GetObject because upload_finalized verifies via HeadObject
        # (HeadObject requires s3:GetObject) — without this every verified upload 403s in prod.
        # Deliberately NO s3:DeleteObject: the producer is write-only for traces. store.log's
        # failed-upload cleanup path (delete_prefix) is best-effort and degrades to a logged
        # warning + an orphan prefix that the janitor (which holds the scoped Delete role below)
        # collects — so a compromised producer can neither erase run history nor other runs' blobs.
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = [for b in aws_s3_bucket.traces : "${b.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.mlflow_artifacts.arn, "${aws_s3_bucket.mlflow_artifacts.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [aws_kms_key.data.arn]
      },
    ], local.mlflow_statements.producer)
  })
}

# --- mcp-reader role: read traces + MLflow, presign the UI, write only the async-scratch prefix
resource "aws_iam_role" "mcp_reader" {
  name               = "${var.name_prefix}-mcp-reader"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "mcp_reader" {
  name = "mcp-reader-access"
  role = aws_iam_role.mcp_reader.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = concat(
          [for b in aws_s3_bucket.traces : b.arn],
          [for b in aws_s3_bucket.traces : "${b.arn}/*"],
          [aws_s3_bucket.mlflow_artifacts.arn, "${aws_s3_bucket.mlflow_artifacts.arn}/*"],
        )
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = ["${aws_s3_bucket.mlflow_artifacts.arn}/scratch/*"] # async MCP job results only
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [aws_kms_key.data.arn]
      },
    ], local.mlflow_statements.reader)
  })
}

# --- janitor role: GC orphaned trace blobs (the ONLY role holding s3:DeleteObject on traces) ----
# Lives in the data-layer (the record of record) regardless of where the janitor's compute runs:
# a cluster teardown must never take the delete-capable identity with it. Trust is EKS Pod Identity
# so a CronJob can assume it; a Lambda placement would swap this principal for lambda.amazonaws.com.
# It reads MLflow authoritatively (GetRun/SearchRuns) to decide orphans and lists/deletes S3 —
# deliberately NOT mcp-reader (readers must stay Delete-less) and NOT the producer (write-only).
#
# On the "app" backend it gets NO MLflow access, because the only action an app offers covers the whole
# REST API: granting the lookup would also grant DeleteRun and DeleteExperiment to the one component
# whose job is deletion, on metadata that no bucket versioning can restore. What that costs is stated
# plainly: with no authoritative run lookup the janitor cannot classify an orphan, so it fails closed
# and keeps every trace prefix. Automatic trace GC therefore needs the "server" backend; on "app",
# retention is the bucket lifecycle rule and deleting a finished campaign is a deliberate act.
resource "aws_iam_role" "janitor" {
  name               = "${var.name_prefix}-janitor"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "janitor" {
  name = "janitor-gc"
  role = aws_iam_role.janitor.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        # Scan run prefixes (ListBucket), read the retention marker (HeadObject needs GetObject),
        # and delete orphan blobs. Scoped to the trace buckets only.
        Effect = "Allow"
        Action = ["s3:ListBucket", "s3:GetObject", "s3:DeleteObject"]
        Resource = concat(
          [for b in aws_s3_bucket.traces : b.arn],
          [for b in aws_s3_bucket.traces : "${b.arn}/*"],
        )
      },
      # Authoritative run lookups to classify orphans (fail-closed on any other MLflow error). Empty on
      # the "app" backend, for the reason in this role's header.
    ], local.mlflow_statements.lookup)
  })
}

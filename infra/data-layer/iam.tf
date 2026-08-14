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

# --- MLflow App role: lets the managed App read/write the artifact bucket ----------------------
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
    Statement = [
      {
        # PutObject to upload; GetObject because upload_finalized verifies via HeadObject
        # (HeadObject requires s3:GetObject) — without this every verified upload 403s in prod.
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
        # Write-only MLflow data plane. Deliberately NO Delete* — the run history is a record of
        # record; a compromised producer must not be able to erase experiments.
        Effect = "Allow"
        Action = [
          "sagemaker-mlflow:CreateExperiment",
          "sagemaker-mlflow:GetExperimentByName",
          "sagemaker-mlflow:GetExperiment",
          "sagemaker-mlflow:CreateRun",
          "sagemaker-mlflow:UpdateRun",
          "sagemaker-mlflow:LogMetric",
          "sagemaker-mlflow:LogParam",
          "sagemaker-mlflow:LogBatch",
          "sagemaker-mlflow:SetTag",
          "sagemaker-mlflow:SearchRuns",
          "sagemaker-mlflow:LogModel",
        ]
        Resource = var.mlflow_app_arn != "" ? [var.mlflow_app_arn] : ["*"]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [aws_kms_key.data.arn]
      },
    ]
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
    Statement = [
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
        Effect = "Allow"
        Action = [
          "sagemaker-mlflow:AccessUI",
          "sagemaker-mlflow:GetExperiment",
          "sagemaker-mlflow:GetRun",
          "sagemaker-mlflow:SearchRuns",
          "sagemaker-mlflow:SearchExperiments",
          "sagemaker-mlflow:ListArtifacts",
          "sagemaker:CreatePresignedMlflowTrackingServerUrl",
        ]
        Resource = var.mlflow_app_arn != "" ? [var.mlflow_app_arn] : ["*"]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [aws_kms_key.data.arn]
      },
    ]
  })
}

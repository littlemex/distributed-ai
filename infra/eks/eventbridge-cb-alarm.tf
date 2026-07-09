# eventbridge-cb-alarm.tf
# One-shot EventBridge Scheduler rule that fires 1 hour before the Capacity Block ends,
# publishing a notification to SNS so the team can gracefully drain workloads.
#
# Uses the at() one-time schedule expression which accepts UTC timestamps in the form:
#   at(yyyy-mm-ddThh:mm:ss)
# The schedule is computed by subtracting 1 hour from var.cb_end_date (RFC3339 string).
#
# Verified: aws_scheduler_schedule resource exists in AWS provider ~>5.80.
# aws scheduler list-schedules in us-east-2 returns HTTP 200 (confirmed).

# ---------------------------------------------------------------------------
# SNS topic for Capacity Block expiry alerts
# ---------------------------------------------------------------------------
resource "aws_sns_topic" "cb_expiry_alert" {
  count = local.has_cb ? 1 : 0
  name  = "${var.cluster_name}-cb-expiry-alert"

  tags = {
    Environment = var.environment
    Project     = "distributed-ai"
  }
}

resource "aws_sns_topic_subscription" "cb_expiry_email" {
  count = local.has_cb ? length(var.cb_alert_email_addresses) : 0

  topic_arn = aws_sns_topic.cb_expiry_alert[0].arn
  protocol  = "email"
  endpoint  = var.cb_alert_email_addresses[count.index]
}

# ---------------------------------------------------------------------------
# IAM role for EventBridge Scheduler → SNS publish
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "scheduler_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.aws_account_id]
    }
  }
}

resource "aws_iam_role" "cb_expiry_scheduler" {
  count              = local.has_cb ? 1 : 0
  name               = "${var.cluster_name}-cb-expiry-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume_role.json

  tags = {
    Environment = var.environment
    Project     = "distributed-ai"
  }
}

data "aws_iam_policy_document" "scheduler_sns_publish" {
  statement {
    actions   = ["sns:Publish"]
    resources = local.has_cb ? [aws_sns_topic.cb_expiry_alert[0].arn] : ["*"]
  }
}

resource "aws_iam_role_policy" "cb_expiry_scheduler_sns" {
  count  = local.has_cb ? 1 : 0
  name   = "sns-publish"
  role   = aws_iam_role.cb_expiry_scheduler[0].id
  policy = data.aws_iam_policy_document.scheduler_sns_publish.json
}

# ---------------------------------------------------------------------------
# EventBridge Scheduler — one-shot at(cb_end_date minus 1 hour)
#
# var.cb_end_date is an RFC3339 timestamp, e.g. "2026-07-12T14:00:00Z".
# timeadd() subtracts 1 hour; formatdate() formats to "yyyy-MM-dd'T'HH:mm:ss"
# which matches the at() expression syntax: at(yyyy-mm-ddThh:mm:ss).
# ---------------------------------------------------------------------------
locals {
  # Compute the trigger time: 1 hour before the Capacity Block end.
  # Guard against empty cb_end_date (no CB purchased) by falling back to a fixed
  # dummy timestamp; the aws_scheduler_schedule resource is created only when
  # local.has_cb is true, so the dummy value is never used at runtime.
  _cb_end_date_safe = var.cb_end_date != "" ? var.cb_end_date : "2000-01-01T00:00:00Z"
  cb_alert_time     = timeadd(local._cb_end_date_safe, "-1h")

  # at() requires the format at(yyyy-mm-ddThh:mm:ss) — no timezone suffix.
  # formatdate token reference: YYYY=year, MM=month, DD=day, HH=hour, mm=minute, ss=second.
  # Single-quoted 'T' is a literal character separator in Terraform's formatdate.
  cb_alert_datetime_str  = formatdate("YYYY-MM-DD'T'HH:mm:ss", local.cb_alert_time)
  cb_alert_schedule_expr = "at(${local.cb_alert_datetime_str})"
}

resource "aws_scheduler_schedule" "cb_expiry_alert" {
  count      = local.has_cb ? 1 : 0
  name       = "${var.cluster_name}-cb-expiry-alert"
  group_name = "default"

  # One-time at() schedule fires once at the computed UTC time.
  schedule_expression          = local.cb_alert_schedule_expr
  schedule_expression_timezone = "UTC"

  # Delete the schedule automatically after it fires.
  action_after_completion = "DELETE"

  flexible_time_window {
    # No flexibility — fire exactly at the scheduled time.
    mode = "OFF"
  }

  target {
    arn      = aws_sns_topic.cb_expiry_alert[0].arn
    role_arn = aws_iam_role.cb_expiry_scheduler[0].arn

    input = jsonencode({
      source      = "eventbridge-scheduler"
      cluster     = var.cluster_name
      reservation = var.cb_reservation_id
      cb_end_date = var.cb_end_date
      message     = "Capacity Block ${var.cb_reservation_id} for cluster ${var.cluster_name} expires at ${var.cb_end_date}. Begin graceful drain now (1 hour remaining)."
    })
  }
}

# ---------------------------------------------------------------------------
# Output the computed alert schedule expression for verification
# ---------------------------------------------------------------------------
output "cb_expiry_alert_schedule_expr" {
  description = "EventBridge at() expression for the CB expiry alert (1 hour before cb_end_date). Empty string when no CB is configured."
  value       = local.has_cb ? local.cb_alert_schedule_expr : ""
}

output "cb_expiry_sns_topic_arn" {
  description = "SNS topic ARN for Capacity Block expiry notifications. Empty string when no CB is configured."
  value       = local.has_cb ? aws_sns_topic.cb_expiry_alert[0].arn : ""
}

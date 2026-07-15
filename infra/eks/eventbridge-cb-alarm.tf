# eventbridge-cb-alarm.tf
# One-shot EventBridge Scheduler rule PER reserved pool that fires 1 hour before that
# pool's Capacity Block ends, publishing to a shared SNS topic so the team can drain
# workloads gracefully. Driven entirely by the per-pool cb_end_date in accelerator_pools —
# a cluster with several Capacity Blocks gets one alert each.
#
# Uses the at() one-time schedule expression (UTC): at(yyyy-mm-ddThh:mm:ss), computed by
# subtracting 1 hour from each pool's cb_end_date (RFC3339). aws_scheduler_schedule exists
# in AWS provider ~>5.80.

locals {
  # Reserved pools that provided a cb_end_date get a pre-expiry alert. Keyed by pool name.
  cb_alert_pools = {
    for k, p in var.accelerator_pools : k => p
    if p.capacity_type == "reserved" && p.cb_end_date != ""
  }

  # Any alert pools at all → provision the shared SNS topic + scheduler role.
  has_cb_alert = length(local.cb_alert_pools) > 0

  # Per-pool at() expression: 1 hour before that pool's cb_end_date.
  # formatdate tokens: YYYY year, MM month, DD day, HH hour, mm minute, ss second;
  # single-quoted 'T' is a literal separator. at() takes no timezone suffix.
  cb_alert_schedule_expr = {
    for k, p in local.cb_alert_pools :
    k => "at(${formatdate("YYYY-MM-DD'T'HH:mm:ss", timeadd(p.cb_end_date, "-1h"))})"
  }
}

# ---------------------------------------------------------------------------
# Shared SNS topic for Capacity Block expiry alerts (one per cluster)
# ---------------------------------------------------------------------------
resource "aws_sns_topic" "cb_expiry_alert" {
  count = local.has_cb_alert ? 1 : 0
  name  = "${var.cluster_name}-cb-expiry-alert"

  tags = {
    Environment = var.environment
    Project     = "distributed-ai"
  }
}

resource "aws_sns_topic_subscription" "cb_expiry_email" {
  count = local.has_cb_alert ? length(var.cb_alert_email_addresses) : 0

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
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "cb_expiry_scheduler" {
  count              = local.has_cb_alert ? 1 : 0
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
    resources = local.has_cb_alert ? [aws_sns_topic.cb_expiry_alert[0].arn] : ["*"]
  }
}

resource "aws_iam_role_policy" "cb_expiry_scheduler_sns" {
  count  = local.has_cb_alert ? 1 : 0
  name   = "sns-publish"
  role   = aws_iam_role.cb_expiry_scheduler[0].id
  policy = data.aws_iam_policy_document.scheduler_sns_publish.json
}

# ---------------------------------------------------------------------------
# EventBridge Scheduler — one per reserved pool, one-shot at(cb_end_date - 1h)
# ---------------------------------------------------------------------------
resource "aws_scheduler_schedule" "cb_expiry_alert" {
  for_each = local.cb_alert_pools

  name       = "${var.cluster_name}-${each.key}-cb-expiry-alert"
  group_name = "default"

  schedule_expression          = local.cb_alert_schedule_expr[each.key]
  schedule_expression_timezone = "UTC"

  # Delete the schedule automatically after it fires.
  action_after_completion = "DELETE"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_sns_topic.cb_expiry_alert[0].arn
    role_arn = aws_iam_role.cb_expiry_scheduler[0].arn

    input = jsonencode({
      source      = "eventbridge-scheduler"
      cluster     = var.cluster_name
      pool        = each.key
      reservation = each.value.cb_reservation_id
      cb_end_date = each.value.cb_end_date
      message     = "Capacity Block ${each.value.cb_reservation_id} (pool ${each.key}, cluster ${var.cluster_name}) expires at ${each.value.cb_end_date}. Begin graceful drain now (1 hour remaining)."
    })
  }
}

# ---------------------------------------------------------------------------
# Outputs — per-pool alert expressions and the shared SNS topic ARN
# ---------------------------------------------------------------------------
output "cb_expiry_alert_schedule_exprs" {
  description = "Map of reserved pool name → EventBridge at() expression for its CB expiry alert (1 hour before cb_end_date). Empty when no pool sets cb_end_date."
  value       = local.cb_alert_schedule_expr
}

output "cb_expiry_sns_topic_arn" {
  description = "Shared SNS topic ARN for Capacity Block expiry notifications. Empty string when no CB alert is configured."
  value       = local.has_cb_alert ? aws_sns_topic.cb_expiry_alert[0].arn : ""
}

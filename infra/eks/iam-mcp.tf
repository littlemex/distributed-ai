################################################################################
# analysis-mcp serving mechanism: the fixed "mcp" namespace + "mcp-reader"
# ServiceAccount + a Pod Identity association to the read-only mcp-reader IAM role
# that the analysis-mcp pod authenticates as (reads MLflow + trace S3).
#
# The IAM role itself is NOT created here — it lives in the separate infra/data-layer
# state (aws_iam_role.mcp_reader), the same cross-state split as the buckets/MLflow App,
# so a cluster teardown can never delete the record-of-record account's IAM. This module
# only associates the fixed ns+SA to that role's ARN (feed it
# `terraform output -raw mcp_reader_role_arn` from infra/data-layer).
#
# The Deployment/Service that runs analysis-mcp is catalog Helm (charts/analysis-mcp),
# applied with `helm template | kubectl apply`; the chart hardcodes the same ns+SA pair
# (charts/analysis-mcp/templates/_helpers.tpl) so the two sides cannot drift.
################################################################################

variable "analysis_mcp_enabled" {
  description = <<-EOT
    Provision the analysis-mcp serving mechanism: the "mcp" namespace, the "mcp-reader"
    ServiceAccount, and its Pod Identity association to var.mcp_reader_role_arn. Default OFF
    (the whole profiling platform is opt-in). Turning it on with mcp_reader_role_arn unset is a
    plan-time error. Reachable via `kubectl port-forward svc/analysis-mcp -n mcp` — see
    charts/analysis-mcp/README.md.
  EOT
  type        = bool
  default     = false
}

variable "mcp_reader_role_arn" {
  description = "ARN of the read-only mcp-reader IAM role from the SEPARATE infra/data-layer state (`terraform output -raw mcp_reader_role_arn` there). Required when analysis_mcp_enabled = true."
  type        = string
  default     = ""

  validation {
    condition     = var.analysis_mcp_enabled == false || var.mcp_reader_role_arn != ""
    error_message = "analysis_mcp_enabled is true but mcp_reader_role_arn is empty — set it to the infra/data-layer mcp_reader_role_arn output, or turn analysis_mcp_enabled off."
  }
}

locals {
  mcp_namespace       = "mcp"
  mcp_service_account = "mcp-reader"
}

resource "kubectl_manifest" "mcp_namespace" {
  count = var.analysis_mcp_enabled ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name   = local.mcp_namespace
      labels = { "pod-security.kubernetes.io/enforce" = "restricted" }
    }
  })
}

resource "kubectl_manifest" "mcp_reader_sa" {
  count = var.analysis_mcp_enabled ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ServiceAccount"
    metadata   = { name = local.mcp_service_account, namespace = local.mcp_namespace }
  })
  depends_on = [kubectl_manifest.mcp_namespace]
}

resource "aws_eks_pod_identity_association" "mcp_reader" {
  count           = var.analysis_mcp_enabled ? 1 : 0
  cluster_name    = module.eks.cluster_name
  namespace       = local.mcp_namespace
  service_account = local.mcp_service_account
  role_arn        = var.mcp_reader_role_arn
  depends_on      = [kubectl_manifest.mcp_reader_sa]
}

output "mcp_namespace" {
  description = "Namespace analysis-mcp's ServiceAccount lives in (null when analysis_mcp_enabled=false)."
  value       = var.analysis_mcp_enabled ? local.mcp_namespace : null
}

################################################################################
# producer wiring: a Pod Identity association mapping the write-side producer role to the
# (namespace, "mcp-producer") ServiceAccount that profiling workloads authenticate as
# (write traces to S3 + log MLflow runs). This is the write-side counterpart to the
# mcp-reader association above; the data-layer contract is that infra/eks associates its
# fixed ServiceAccounts to BOTH producer_role_arn and mcp_reader_role_arn.
#
# The IAM role itself is NOT created here — it lives in the separate infra/data-layer state
# (aws_iam_role.producer). Feed `terraform output -raw producer_role_arn` from there.
#
# Only the association is created here — NOT the ServiceAccount and NOT the namespace.
# aws_eks_pod_identity_association is a control-plane record keyed by (cluster, namespace, SA
# name) strings; it neither requires the namespace/SA to exist nor is affected by their
# lifecycle. This is deliberate: the producer runs in the profiling WORKLOAD's namespace
# (var.mcp_producer_namespaces), which is owned by whoever deploys the workload — not by this
# module. Creating the SA here would fail if that namespace does not exist yet, and creating
# the namespace here would let a cluster teardown delete a shared workload namespace. So the
# workload deploys the "mcp-producer" ServiceAccount in that namespace; the association below
# stays dormant until a Pod using it runs, then injects the producer role's credentials.
# Self-gating on a non-empty role ARN keeps it opt-in without a separate toggle.
################################################################################

variable "mcp_producer_role_arn" {
  description = "ARN of the write-side producer IAM role from the SEPARATE infra/data-layer state (`terraform output -raw producer_role_arn` there). When non-empty, infra/eks creates a Pod Identity association mapping this role to the `mcp-producer` ServiceAccount in every entry of var.mcp_producer_namespaces, so profiling workloads can write traces and log MLflow runs. The ServiceAccount itself is created by the workload, not here. Empty (default) skips producer wiring."
  type        = string
  default     = ""

  validation {
    # Non-empty role name required (bare "role/" is rejected); partition left open so GovCloud
    # (aws-us-gov) / China (aws-cn) ARNs pass. A malformed value would otherwise be wired silently.
    condition     = var.mcp_producer_role_arn == "" || can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/.+", var.mcp_producer_role_arn))
    error_message = "mcp_producer_role_arn must be empty or a valid IAM role ARN (arn:<partition>:iam::<account>:role/<name> with a non-empty name)."
  }
}

variable "mcp_producer_namespaces" {
  description = "Namespaces the producer Pod Identity associations target — every namespace whose workloads may collect profiles. Each gets one association for the `mcp-producer` ServiceAccount; the ServiceAccount itself is created by the workload, not here. Namespaces are not created or validated for existence (an association is just a control-plane record keyed by strings), so listing a namespace that does not exist yet is allowed. This set is the allow-list of namespaces permitted to write traces and log MLflow runs — it is the audit point for that permission. Only used when mcp_producer_role_arn is set."
  type        = set(string)
  default     = ["distai"]

  validation {
    # EKS validates each namespace string as a DNS-1123 label; catch an invalid value at plan time
    # instead of an InvalidParameterException at apply time.
    condition = alltrue([
      for ns in var.mcp_producer_namespaces :
      can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", ns)) && length(ns) <= 63
    ])
    error_message = "every entry of mcp_producer_namespaces must be a valid DNS-1123 label (lowercase alphanumerics and '-', starting/ending alphanumeric, <=63 chars)."
  }

  validation {
    condition     = length(var.mcp_producer_namespaces) > 0
    error_message = "mcp_producer_namespaces must not be empty — leave mcp_producer_role_arn empty to turn producer wiring off instead."
  }
}

locals {
  producer_enabled    = var.mcp_producer_role_arn != ""
  producer_sa         = "mcp-producer"
  producer_namespaces = local.producer_enabled ? var.mcp_producer_namespaces : toset([])
}

resource "aws_eks_pod_identity_association" "producer" {
  for_each        = local.producer_namespaces
  cluster_name    = module.eks.cluster_name
  namespace       = each.value
  service_account = local.producer_sa
  role_arn        = var.mcp_producer_role_arn

  lifecycle {
    precondition {
      # Pod Identity cannot assume a cross-account role directly; fail at plan time rather than at
      # apply time if the role ARN is in a different account than this cluster.
      condition     = can(regex("::${data.aws_caller_identity.current.account_id}:role/", var.mcp_producer_role_arn))
      error_message = "mcp_producer_role_arn must be a role in this cluster's own account — EKS Pod Identity does not assume cross-account roles."
    }
  }
}

# The association was a single count-indexed resource keyed to one namespace. Carry the existing
# instance over to the for_each key so widening the variable does not destroy and recreate it — a
# recreate would briefly strip credentials from running producer Pods.
moved {
  from = aws_eks_pod_identity_association.producer[0]
  to   = aws_eks_pod_identity_association.producer["distai"]
}

# Single source of truth for the infra/workload contract: the workload must create a ServiceAccount
# with this name in this namespace for the association to take effect.
output "mcp_producer_service_account" {
  description = "ServiceAccount name the producer Pod Identity association targets (create this SA in each of mcp_producer_namespaces from your profiling workload). Null when producer wiring is off."
  value       = local.producer_enabled ? local.producer_sa : null
}

output "mcp_producer_namespaces" {
  description = "Namespaces the producer Pod Identity associations target. Empty when producer wiring is off."
  value       = local.producer_namespaces
}

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
# producer wiring: the fixed "mcp-producer" ServiceAccount + a Pod Identity association
# to the write-side producer IAM role that profiling workloads authenticate as
# (write traces to S3 + log MLflow runs). This is the write-side counterpart to the
# mcp-reader association above; the data-layer contract is that infra/eks associates
# its fixed ServiceAccounts to BOTH producer_role_arn and mcp_reader_role_arn.
#
# The IAM role itself is NOT created here — it lives in the separate infra/data-layer
# state (aws_iam_role.producer). Feed `terraform output -raw producer_role_arn` from there.
#
# Unlike mcp-reader (which gets its own dedicated "mcp" namespace), the producer runs in
# the namespace where the profiling WORKLOAD runs, so that namespace is assumed to already
# exist (e.g. the workshop's "distai") and is NOT created here — only the ServiceAccount and
# the association are. Self-gating on a non-empty role ARN keeps it opt-in without a separate
# toggle.
################################################################################

variable "mcp_producer_role_arn" {
  description = "ARN of the write-side producer IAM role from the SEPARATE infra/data-layer state (`terraform output -raw producer_role_arn` there). When non-empty, infra/eks creates the `mcp-producer` ServiceAccount in var.mcp_producer_namespace and associates it via Pod Identity so profiling workloads can write traces and log MLflow runs. Empty (default) skips producer wiring."
  type        = string
  default     = ""

  validation {
    condition     = var.mcp_producer_role_arn == "" || can(regex("^arn:aws:iam::[0-9]{12}:role/", var.mcp_producer_role_arn))
    error_message = "mcp_producer_role_arn must be empty or a valid IAM role ARN (arn:aws:iam::<account>:role/<name>) — a malformed value would be wired silently."
  }
}

variable "mcp_producer_namespace" {
  description = "Existing namespace where the profiling `mcp-producer` ServiceAccount is created — the namespace your profiling workloads run in. Must already exist (not created here). Only used when mcp_producer_role_arn is set."
  type        = string
  default     = "distai"
}

locals {
  producer_enabled = var.mcp_producer_role_arn != ""
  producer_sa      = "mcp-producer"
}

resource "kubectl_manifest" "producer_sa" {
  count = local.producer_enabled ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ServiceAccount"
    metadata   = { name = local.producer_sa, namespace = var.mcp_producer_namespace }
  })
}

resource "aws_eks_pod_identity_association" "producer" {
  count           = local.producer_enabled ? 1 : 0
  cluster_name    = module.eks.cluster_name
  namespace       = var.mcp_producer_namespace
  service_account = local.producer_sa
  role_arn        = var.mcp_producer_role_arn
  depends_on      = [kubectl_manifest.producer_sa]
}

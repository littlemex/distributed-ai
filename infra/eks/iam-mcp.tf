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

variable "mcp_producer_role_arn" {
  description = <<-EOT
    ARN of the producer IAM role from the SEPARATE infra/data-layer state
    (`terraform output -raw producer_role_arn` there). Provisions the "producer" ServiceAccount in
    the mcp namespace and its Pod Identity association so a producer Pod (which writes traces to the
    trace bucket and logs runs to MLflow via store.log) can authenticate. OPTIONAL: leave empty if no
    in-cluster producer runs here. Only takes effect when analysis_mcp_enabled = true (the SA lives in
    the same mcp namespace this module creates).
  EOT
  type        = string
  default     = ""
}

locals {
  mcp_namespace            = "mcp"
  mcp_service_account      = "mcp-reader"
  producer_service_account = "producer"
  # Wire the producer SA only when the mcp namespace is being created AND a role ARN was handed in.
  create_producer = var.analysis_mcp_enabled && var.mcp_producer_role_arn != ""
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

# --- producer side: the workload that writes traces + logs MLflow runs via store.log -----------
# Mirrors the mcp-reader wiring above. The IAM role lives in infra/data-layer
# (aws_iam_role.producer, `terraform output -raw producer_role_arn`); this module only binds the
# fixed "producer" SA in the mcp namespace to it via Pod Identity.
resource "kubectl_manifest" "producer_sa" {
  count = local.create_producer ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ServiceAccount"
    metadata   = { name = local.producer_service_account, namespace = local.mcp_namespace }
  })
  depends_on = [kubectl_manifest.mcp_namespace]
}

resource "aws_eks_pod_identity_association" "producer" {
  count           = local.create_producer ? 1 : 0
  cluster_name    = module.eks.cluster_name
  namespace       = local.mcp_namespace
  service_account = local.producer_service_account
  role_arn        = var.mcp_producer_role_arn
  depends_on      = [kubectl_manifest.producer_sa]
}

output "mcp_namespace" {
  description = "Namespace analysis-mcp's ServiceAccount lives in (null when analysis_mcp_enabled=false)."
  value       = var.analysis_mcp_enabled ? local.mcp_namespace : null
}

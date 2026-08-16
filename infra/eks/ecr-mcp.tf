################################################################################
# ECR repositories for the profiling MCP deploy images. The in-cluster BuildKit
# builder (image-builder.tf) can PUSH to any repo in this account+region, but ECR
# does NOT auto-create a repository on push — so the repos the mcp-host images land
# in must exist first. Created with the analysis-mcp mechanism (same opt-in toggle)
# so a bare cluster that never turns the profiling platform on carries no extra ECR.
#
#   accelprof           - the analysis MCP image family: the base (Dockerfile.accelprof-analysis)
#                         and its tool-layered variants nsys / neuron, distinguished by TAG on
#                         this one repo (v1 = base, v1-nsys, v1-neuron, ...).
#   accelprof-knowledge - the knowledge MCP image (Dockerfile.accelprof-knowledge).
################################################################################

variable "mcp_ecr_name_prefix" {
  description = <<-EOT
    Optional prefix for the MCP ECR repository names. Empty (default) = the book's fixed names
    "accelprof" / "accelprof-knowledge". Set a prefix (e.g. "wsverify-") to stand up a SECOND
    profiling-MCP deployment in the same account+region without colliding on the account-global
    ECR repository names.
  EOT
  type        = string
  default     = ""
}

resource "aws_ecr_repository" "accelprof" {
  count                = var.analysis_mcp_enabled ? 1 : 0
  name                 = "${var.mcp_ecr_name_prefix}accelprof"
  image_tag_mutability = "MUTABLE"
  # force_delete: a workshop cluster's teardown (analysis_mcp_enabled=false apply, or destroy)
  # must not wedge on a repo that still holds pushed image tags.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = false
  }

  tags = var.tags
}

resource "aws_ecr_repository" "accelprof_knowledge" {
  count                = var.analysis_mcp_enabled ? 1 : 0
  name                 = "${var.mcp_ecr_name_prefix}accelprof-knowledge"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = false
  }

  tags = var.tags
}

output "accelprof_ecr_repository_url" {
  description = "ECR repo URL for the accelprof analysis MCP image family (null when analysis_mcp_enabled=false)."
  value       = var.analysis_mcp_enabled ? aws_ecr_repository.accelprof[0].repository_url : null
}

output "accelprof_knowledge_ecr_repository_url" {
  description = "ECR repo URL for the accelprof-knowledge MCP image (null when analysis_mcp_enabled=false)."
  value       = var.analysis_mcp_enabled ? aws_ecr_repository.accelprof_knowledge[0].repository_url : null
}

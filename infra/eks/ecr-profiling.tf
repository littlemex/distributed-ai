################################################################################
# ECR repositories for the profiling platform images.
#
# ECR does not create a repository on push, so the analysis and knowledge images need their
# repositories to exist before anything can publish them. They are gated on the same toggle as the
# rest of the cluster-side profiling wiring, so a cluster that does not run the platform gets
# nothing. Images are rebuildable artifacts, hence force_delete: a teardown must not wedge on a
# repository that still holds tags.
################################################################################

resource "aws_ecr_repository" "profiling" {
  for_each = var.analysis_mcp_enabled ? toset(["accelprof", "accelprof-knowledge"]) : toset([])

  name                 = each.value
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = false
  }

  tags = var.tags
}

resource "aws_ecr_lifecycle_policy" "profiling" {
  for_each   = aws_ecr_repository.profiling
  repository = each.value.name

  # Keep the platform's history short: values pin images by digest, so superseded tags are only
  # useful for a rollback within the recent past.
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire all but the 10 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

output "profiling_ecr_repositories" {
  description = "Map of profiling image name to its ECR repository URL (empty when analysis_mcp_enabled=false)."
  value       = { for k, v in aws_ecr_repository.profiling : k => v.repository_url }
}

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

  # The deployment pins images by digest, which is the reason a digest has to stay pullable rather than
  # a reason it can be discarded. The build tags are moving ones (v1, v1-nsys), so every rebuild leaves
  # the previously deployed digest untagged while a running Deployment still names it. Expiring by
  # count over "any" tag status therefore deleted images that were in use, and nothing noticed: the
  # Pods were already running, so the pull failure waited for the next node replacement or eviction and
  # then returned 403 for an image nobody had changed.
  #
  # build-profiling-images.sh gives every published digest a second, never-moving tag (pinned-<digest>)
  # so that a deployed digest is never merely untagged. The rules below then bound the history without
  # being able to delete something a Deployment names, until it is more than 30 builds old:
  # untagged images are genuine leftovers (an interrupted push), and the pinned tags are the history.
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days; a published digest always carries pinned-<digest>"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the 30 most recent pinned digests"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["pinned-"]
          countType     = "imageCountMoreThan"
          countNumber   = 30
        }
        action = { type = "expire" }
      },
    ]
  })
}

output "profiling_ecr_repositories" {
  description = "Map of profiling image name to its ECR repository URL (empty when analysis_mcp_enabled=false)."
  value       = { for k, v in aws_ecr_repository.profiling : k => v.repository_url }
}

################################################################################
# ComfyUI image: a dedicated ECR repository for the in-cluster BuildKit builder.
#
# The base module provisions the GENERIC in-cluster builder mechanism (image-builder.tf):
# an "image-builder" namespace + ServiceAccount, an IAM role, and a Pod Identity
# association. As of the base module's generic-builder change, that role's ECR push
# permission is extensible via `image_builder_additional_ecr_repository_arns` — so we
# only need to (1) create the ComfyUI repo here and (2) hand its ARN to the module
# (see main.tf). The BuildKit Job then runs under the existing "image-builder"
# ServiceAccount and can push to this repo. No IAM role/policy is managed from this
# root — the module owns the builder's identity and permissions; we own the repo.
#
# This is the intended consumer pattern: the builder is "where you build", the repo is
# "what you build" and belongs to the consumer. Because the repo is created here and its
# ARN is an INPUT to module.cluster, there is no dependency cycle (the repo does not
# depend on the cluster).
################################################################################

locals {
  comfyui_ecr_repo_name = coalesce(
    var.comfyui_image_repository_name,
    "${var.cluster_name}-comfyui",
  )
}

resource "aws_ecr_repository" "comfyui" {
  name                 = local.comfyui_ecr_repo_name
  image_tag_mutability = "MUTABLE" # tags are bumped (v1 -> v2) to force a rebuild; see the build Job.

  image_scanning_configuration {
    scan_on_push = true
  }

  # A smoke/experiment cluster's `terraform destroy` must not wedge on a repo that still
  # holds pushed images (matches the base module's ddp-sample repo).
  force_delete = true

  tags = merge(var.tags, {
    Name      = local.comfyui_ecr_repo_name
    Component = "comfyui-image"
  })
}

# Lifecycle policy: keep the ECR repo from accumulating stale build tags. Retains the
# most recent 10 images; older ones expire. Purely cost hygiene for an experiment repo.
resource "aws_ecr_lifecycle_policy" "comfyui" {
  repository = aws_ecr_repository.comfyui.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only the 10 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

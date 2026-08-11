################################################################################
# ComfyUI + MiniMax-H3 on EKS (us-west-2) — root module.
#
# A thin wrapper over the reusable ../../infra/eks cluster module. It:
#   1. Assembles a single GPU accelerator pool sized for ComfyUI + MiniMax-H3
#      (plus any extra pools the caller supplies), and
#   2. Turns FSx Lustre OFF and keeps FSx OpenZFS ON as the /shared model+output
#      layer, co-located in one AZ with the GPU pool.
# The ComfyUI-specific ECR repository + IAM live in comfyui-image-builder.tf.
#
# State is isolated in THIS working directory (see versions.tf) — the base
# infra/eks state (us-east-2 / distai-eks-smoke) is never referenced or mutated.
################################################################################

locals {
  # The ComfyUI serving pool, expressed in the base module's accelerator_pools
  # schema. device_plugin=nvidia pulls in the GPU Operator; EFA is derived (g6e
  # single-GPU sizes report 0 EFA, so no EFA add-on is installed). zone="" derives
  # the first cluster AZ, co-located with the OpenZFS filesystem.
  comfyui_pool = {
    (var.gpu_pool_name) = {
      instance_types = var.gpu_instance_types
      device_plugin  = "nvidia"
      capacity_types = var.gpu_capacity_types
      zone           = var.gpu_pool_zone
      volume_size    = var.gpu_node_volume_size
      disruption     = var.gpu_pool_disruption
      # Upper bound on graceful drain. The ComfyUI pod carries karpenter.sh/do-not-disrupt, which
      # blocks VOLUNTARY disruption (consolidation) — correct for a running generation — but on
      # `terraform destroy` the NodePool delete must still drain the node. Without a cap, the
      # NodeClaim finalizer can wait indefinitely on a do-not-disrupt pod and hang the destroy.
      # terminationGracePeriod forces the drain to complete within this window. The runbook also
      # deletes the Deployment first; this is the belt-and-suspenders backstop.
      termination_grace_period = var.gpu_pool_termination_grace_period
    }
  }

  # Merge the ComfyUI pool with any caller-supplied extra pools. A key collision
  # is a user error (defining a second pool that reuses gpu_pool_name); fail loudly
  # rather than let merge() silently drop one side.
  accelerator_pools = merge(local.comfyui_pool, var.extra_accelerator_pools)
}

# Guard: extra_accelerator_pools must not reuse the ComfyUI pool's key.
resource "terraform_data" "pool_key_collision_guard" {
  lifecycle {
    precondition {
      condition     = !contains(keys(var.extra_accelerator_pools), var.gpu_pool_name)
      error_message = "extra_accelerator_pools reuses gpu_pool_name (\"${var.gpu_pool_name}\"); merge() would silently drop one definition. Rename the extra pool or change gpu_pool_name."
    }
  }
}

module "cluster" {
  source = "../../infra/eks"

  # Identity / placement
  region              = var.region
  cluster_name        = var.cluster_name
  aws_profile         = var.aws_profile
  expected_account_id = var.expected_account_id
  environment         = var.environment
  tags                = var.tags

  # Accelerator pools (ComfyUI + any extras)
  accelerator_pools = local.accelerator_pools

  # Storage: OpenZFS ON (model + output /shared layer), Lustre configurable (OFF by
  # default here), EFS off. All single-AZ, pinned to the same AZ as the GPU pool.
  openzfs_enabled              = true
  openzfs_subnet_index         = var.storage_subnet_index
  openzfs_storage_capacity_gib = var.openzfs_storage_capacity_gib
  openzfs_throughput_capacity  = var.openzfs_throughput_capacity
  fsx_enabled                  = var.fsx_lustre_enabled
  fsx_subnet_index             = var.storage_subnet_index
  efs_enabled                  = false

  # No public ingress: ComfyUI has no auth and exposes a Web-UI RCE surface, so it is
  # reached over `kubectl port-forward`, never a public ALB/CloudFront. (The base
  # module's demo_app / cloudfront path stays off — its default.)
  enable_demo_app   = false
  enable_cloudfront = false

  # The in-cluster image builder mechanism (ECR/IAM/SA for BuildKit) is on by default in
  # the base module. We reuse its ServiceAccount + Pod Identity to build the ComfyUI image,
  # and grant that builder push access to OUR repo by handing its ARN to the module's
  # generic additional-repos input (no IAM managed from this root — see comfyui-image-builder.tf).
  image_builder_additional_ecr_repository_arns = [aws_ecr_repository.comfyui.arn]

  # Kubeflow Trainer is training-only — not needed for inference — so turn it off.
  trainer_enabled = false
}

################################################################################
# Root-module outputs. Everything scripts/up.sh and the
# helper scripts need, so no value is ever reconstructed by hand.
################################################################################

output "cluster_name" {
  description = "EKS cluster name — pass to `aws eks update-kubeconfig`."
  value       = module.cluster.cluster_name
}

output "region" {
  description = "AWS region the cluster runs in."
  value       = var.region
}

output "comfyui_pool_name" {
  description = "Karpenter pool key / node-role label the ComfyUI pod targets (charts/comfyui comfyui.nodeRole)."
  value       = var.gpu_pool_name
}

output "comfyui_ecr_url" {
  description = "ECR repository URL for the ComfyUI image. Pass to the BuildKit build Job (imageBuild.repository) and to the ComfyUI Deployment (comfyui.image)."
  value       = aws_ecr_repository.comfyui.repository_url
}

output "image_builder_namespace" {
  description = "Namespace of the in-cluster BuildKit builder (base module). The ComfyUI build Job runs here."
  value       = "image-builder"
}

output "shared_storage" {
  description = "Shared-storage layers and the static PV each backs. ComfyUI mounts the OpenZFS PV (openzfs-shared) for model weights + outputs. Bind a PVC to .fsx_openzfs.persistent_volume."
  value       = module.cluster.shared_storage
}

output "openzfs_persistent_volume" {
  description = "Convenience: the static PV name ComfyUI's PVC binds to for /shared (model weights + outputs)."
  value       = module.cluster.shared_storage.fsx_openzfs.persistent_volume
}

output "accelerator_pool_efa_schedulable" {
  description = "Per-pool schedulable EFA count. The ComfyUI g6e single-GPU pool has no EFA (0) — informational only."
  value       = module.cluster.accelerator_pool_efa_schedulable
}

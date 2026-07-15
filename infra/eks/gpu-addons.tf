# gpu-addons.tf
# GPU-related Kubernetes add-ons. Each activates based on the accelerator pools present:
#   1. NVIDIA GPU Operator      (var.gpu_operator_chart_version) — only if a GPU pool exists
#   2. AWS EFA k8s Device Plugin (var.efa_device_plugin_chart_version) — if any pool uses EFA
#      (shared by GPU and Neuron pools; trn2/p5/p5en/g6e all surface EFA via this plugin)
#   3. Kubeflow MPI Operator     (var.mpi_operator_version) — always (multi-node launcher)
# The Neuron device plugin is a separate add-on (neuron-addons.tf).
#
# Verified facts:
#   - gpu-operator chart from helm.ngc.nvidia.com/nvidia. Top-level values keys confirmed
#     via `helm show values`: driver.enabled, driver.rdma.enabled, driver.rdma.useHostMofed,
#     gdrcopy.enabled, operator.tolerations.
#   - aws-efa-k8s-device-plugin chart from aws.github.io/eks-charts. The chart version
#     differs from the app/image version; p5en.48xlarge/p5.48xlarge are in the default
#     supportedInstanceLabels list. (g6e.12xlarge is NOT — see the EFA gotcha in the
#     README/blog; on g6e the plugin still advertises EFA once an efa-only ENI exists.)
#   - mpi-operator v2beta1 single-file manifest is published per release tag on GitHub.

locals {
  # GPU Operator Helm values, assembled once so the release stays declarative and diffs
  # are readable (vs. many indexed `set {}` blocks).
  #
  # driver.enabled defaults to false because the EKS AL2023 GPU AMI already ships the
  # NVIDIA driver. driver.rdma.* only takes effect when the operator manages the driver,
  # so it is included ONLY when var.gpu_operator_install_driver is true. useHostMofed is
  # false: AWS EFA uses libfabric + the `efa` kernel module, not Mellanox OFED, so there
  # is no host MOFED to reuse — forcing useHostMofed=true would make the driver search for
  # a MOFED stack that does not exist on EFA nodes.
  gpu_operator_values = merge(
    {
      operator = {
        tolerations = [
          { key = "nvidia.com/gpu", operator = "Exists", effect = "NoSchedule" },
          { key = "vpc.amazonaws.com/efa", operator = "Exists", effect = "NoSchedule" },
        ]
      }
      driver = merge(
        { enabled = var.gpu_operator_install_driver },
        var.gpu_operator_install_driver ? {
          rdma = { enabled = true, useHostMofed = false }
        } : {}
      )
      # gdrcopy requires the gdrdrv kernel module; when it is absent the operator's
      # gdrcopy-validation blocks forever and the device plugin never advertises GPUs.
      # Off by default; gdrcopy is a GPUDirect latency optimization, not required for NCCL.
      gdrcopy = { enabled = var.gpu_operator_enable_gdrcopy }
    }
  )

  # EFA device plugin tolerations. The capacity-reservation taint value varies per CB, so
  # use operator: Exists.
  efa_device_plugin_values = {
    tolerations = [
      { key = "capacity-reservation", operator = "Exists", effect = "NoSchedule" },
      { key = "nvidia.com/gpu", operator = "Exists", effect = "NoSchedule" },
    ]
  }
}

# ---------------------------------------------------------------------------
# 1. NVIDIA GPU Operator — only when a GPU (nvidia) accelerator pool exists.
# ---------------------------------------------------------------------------
resource "helm_release" "gpu_operator" {
  count = local.has_gpu_pool ? 1 : 0

  name             = "gpu-operator"
  repository       = "https://helm.ngc.nvidia.com/nvidia"
  chart            = "gpu-operator"
  version          = var.gpu_operator_chart_version
  namespace        = "gpu-operator"
  create_namespace = true

  values = [yamlencode(local.gpu_operator_values)]

  depends_on = [helm_release.karpenter]
}

# ---------------------------------------------------------------------------
# 2. AWS EFA k8s Device Plugin — when any pool requests EFA (GPU or Neuron).
#    trn2/p5/p5en/g6e all surface EFA through this same plugin, so it is shared.
# ---------------------------------------------------------------------------
resource "helm_release" "aws_efa_k8s_device_plugin" {
  count = local.has_efa_pool ? 1 : 0

  name             = "aws-efa-k8s-device-plugin"
  repository       = "https://aws.github.io/eks-charts"
  chart            = "aws-efa-k8s-device-plugin"
  version          = var.efa_device_plugin_chart_version
  namespace        = "kube-system"
  create_namespace = false

  values = [yamlencode(local.efa_device_plugin_values)]

  depends_on = [helm_release.karpenter]
}

# ---------------------------------------------------------------------------
# 3. Kubeflow MPI Operator
#    Deployed via kubectl_manifest from the official upstream single-file YAML at the
#    release tag var.mpi_operator_version. The gavinbunney/kubectl provider's
#    kubectl_file_documents data source splits the multi-doc YAML into individual docs.
# ---------------------------------------------------------------------------
data "http" "mpi_operator_manifest" {
  url = "https://raw.githubusercontent.com/kubeflow/mpi-operator/${var.mpi_operator_version}/deploy/v2beta1/mpi-operator.yaml"
}

data "kubectl_file_documents" "mpi_operator" {
  content = data.http.mpi_operator_manifest.response_body
}

resource "kubectl_manifest" "mpi_operator" {
  for_each  = data.kubectl_file_documents.mpi_operator.manifests
  yaml_body = each.value

  # The MPIJob CRD is large; a client-side apply stores the whole schema in the
  # last-applied-configuration annotation and exceeds the 262144-byte limit.
  # Server-side apply avoids that annotation entirely.
  server_side_apply = true

  # The aggregated ClusterRoles (kubeflow-mpijobs-admin/edit/view) have their
  # .rules populated by the cluster's clusterrole-aggregation-controller, which
  # then owns that field. Server-side apply conflicts with it; force ownership
  # back to this manifest (the aggregation controller re-reconciles harmlessly).
  force_conflicts = true

  # Ignore updates to fields managed by the operator's own controllers.
  ignore_fields = ["metadata.annotations"]

  # The MPI Operator runs on system nodes and does not depend on the GPU stack; it only
  # needs the cluster API to be reachable (the kubectl provider already targets module.eks).
  depends_on = [module.eks]
}

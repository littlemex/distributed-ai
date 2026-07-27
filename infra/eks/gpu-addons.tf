# gpu-addons.tf
# GPU-related Kubernetes add-ons. Each activates based on the accelerator pools present:
#   1. NVIDIA GPU Operator      (var.gpu_operator_chart_version) — only if a GPU pool exists
#   2. AWS EFA k8s Device Plugin (var.efa_device_plugin_chart_version) — if any pool uses EFA
#      (shared by GPU and Neuron pools; trn2/p5/p5en/g6e all surface EFA via this plugin)
#   3. Kubeflow Training Operator (var.training_operator_version) — always (PyTorchJob)
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
#   - training-operator standalone manifest is published per release tag on GitHub; it is the
#     idiomatic operator for PyTorchJob (kubeflow.org/v1), the same one the awsome-distributed-ai
#     DDP sample installs. It injects MASTER_ADDR/MASTER_PORT/WORLD_SIZE/RANK into each pod so a
#     PyTorchJob needs no sshd/OpenMPI (that was the tax of the old MPIJob-on-PyTorch approach).

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
  # Tolerations applied to BOTH the operator controller and its per-node operands
  # (device plugin, feature discovery, validator). The operands run on the GPU nodes, so
  # they must tolerate the accelerator taints; the controller is scheduled by the same set
  # harmlessly. capacity-reservation (value varies per CB) uses operator: Exists.
  gpu_operator_tolerations = [
    { key = "nvidia.com/gpu", operator = "Exists", effect = "NoSchedule" },
    { key = "vpc.amazonaws.com/efa", operator = "Exists", effect = "NoSchedule" },
    { key = "capacity-reservation", operator = "Exists", effect = "NoSchedule" },
  ]

  gpu_operator_values = merge(
    {
      operator = {
        tolerations = local.gpu_operator_tolerations
      }
      daemonsets = {
        tolerations = local.gpu_operator_tolerations
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

  # EFA device plugin tolerations. EFA is used by BOTH GPU and Neuron pools, so the DaemonSet
  # must tolerate the nvidia AND neuron accelerator taints, plus the per-CB capacity-reservation
  # taint (value varies per reservation → operator: Exists). Missing the neuron toleration would
  # keep the plugin off trn2 nodes, so vpc.amazonaws.com/efa is never advertised there.
  # Instance types that any EFA-enabled pool may launch. The aws-efa-k8s-device-plugin chart
  # gates its DaemonSet with a nodeAffinity on node.kubernetes.io/instance-type built from
  # supportedInstanceLabels; the CHART DEFAULT list does not include every EFA type (e.g.
  # g6e.12xlarge is absent). On a type outside the default list the plugin Pod never schedules,
  # so vpc.amazonaws.com/efa is never advertised and any pod requesting it Pends forever — the
  # same "only the type we happened to test works" trap as other silent-fallback bugs. Derive
  # the list from the pools that actually use EFA so it always covers what this cluster runs.
  efa_supported_instance_types = distinct(flatten([
    for k, p in var.accelerator_pools : p.instance_types if local.pool_efa[k].count > 0
  ]))

  # EFA device plugin tolerations. EFA is used by BOTH GPU and Neuron pools, so the DaemonSet
  # must tolerate the nvidia AND neuron accelerator taints, plus the per-CB capacity-reservation
  # taint (value varies per reservation → operator: Exists). Missing the neuron toleration would
  # keep the plugin off trn2 nodes, so vpc.amazonaws.com/efa is never advertised there.
  efa_device_plugin_values = merge(
    {
      tolerations = [
        { key = "capacity-reservation", operator = "Exists", effect = "NoSchedule" },
        { key = "nvidia.com/gpu", operator = "Exists", effect = "NoSchedule" },
        { key = "aws.amazon.com/neuron", operator = "Exists", effect = "NoSchedule" },
      ]
    },
    # Only override supportedInstanceLabels when we have types to add; an empty list would
    # blank the chart default and strand the plugin everywhere.
    length(local.efa_supported_instance_types) > 0 ? {
      supportedInstanceLabels = {
        keys   = ["node.kubernetes.io/instance-type"]
        values = local.efa_supported_instance_types
      }
    } : {}
  )
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

  # Destroy ordering: null_resource.wait_for_node_drain (karpenter.tf) depends_on this
  # release, so it is destroyed only AFTER the drain-wait completes — the GPU Operator
  # manages a per-node ClusterPolicy/device-plugin DaemonSet, and removing it while a GPU
  # node is still draining can itself stall (observed live: an uninstall got stuck
  # "uninstalling" with a live GPU node present).
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

  # See the identical comment on helm_release.gpu_operator above.
  depends_on = [helm_release.karpenter]
}

# ---------------------------------------------------------------------------
# 3. Kubeflow Training Operator (optional; PyTorchJob multi-node launcher)
#    Applied from a VENDORED manifest committed at manifests/training-operator-<version>.yaml
#    (not fetched at plan time — an upstream tag is mutable and a plan-time HTTP dependency
#    is fragile). Refresh it by re-rendering the release's standalone overlay when bumping the
#    version:
#      kubectl kustomize "github.com/kubeflow/training-operator/manifests/overlays/standalone?ref=<version>" \
#        > manifests/training-operator-<version>.yaml
#    Gated by var.training_operator_enabled. The gavinbunney/kubectl provider's
#    kubectl_file_documents splits the multi-doc YAML into individual docs.
# ---------------------------------------------------------------------------
data "kubectl_file_documents" "training_operator" {
  count   = var.training_operator_enabled ? 1 : 0
  content = file("${path.module}/manifests/training-operator-${var.training_operator_version}.yaml")
}

resource "kubectl_manifest" "training_operator" {
  for_each  = var.training_operator_enabled ? data.kubectl_file_documents.training_operator[0].manifests : {}
  yaml_body = each.value

  # The PyTorchJob (and sibling) CRDs are large; a client-side apply stores the whole schema
  # in the last-applied-configuration annotation and exceeds the 262144-byte limit.
  # Server-side apply avoids that annotation entirely.
  server_side_apply = true

  # The aggregated ClusterRoles (kubeflow-training-admin/edit/view) have their .rules
  # populated by the cluster's clusterrole-aggregation-controller, which then owns that
  # field. Server-side apply conflicts with it; force ownership back to this manifest (the
  # aggregation controller re-reconciles harmlessly). The webhook caBundle is likewise
  # written by the operator's own cert-controller at startup, so let it own that too.
  force_conflicts = true

  # Ignore updates to fields managed by the operator's own controllers (webhook caBundle,
  # operator-set annotations).
  ignore_fields = ["metadata.annotations", "webhooks"]

  # The Training Operator runs on system nodes and does not depend on the GPU stack; it only
  # needs the cluster API to be reachable (the kubectl provider already targets module.eks).
  depends_on = [module.eks]
}

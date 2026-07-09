# gpu-addons.tf
# GPU-related Kubernetes add-ons:
#   1. NVIDIA GPU Operator v25.10.1
#   2. AWS EFA k8s Device Plugin v0.5.29
#   3. MPI Operator v0.6.0
#
# Verified facts:
#   - gpu-operator chart v25.10.1 from helm.ngc.nvidia.com/nvidia
#     Top-level values keys (confirmed via `helm show values`):
#       driver.rdma.enabled       (bool, default: false)
#       driver.rdma.useHostMofed  (bool, default: false)
#       gdrcopy.enabled           (bool, default: false)
#   - aws-efa-k8s-device-plugin chart v0.5.29 (appVersion v0.5.20) from aws.github.io/eks-charts
#     p5en.48xlarge is in the default supportedInstanceLabels list.
#   - mpi-operator v0.6.0 official manifest:
#     https://raw.githubusercontent.com/kubeflow/mpi-operator/v0.6.0/deploy/v2beta1/mpi-operator.yaml
#     (HTTP 200 confirmed, tag v0.6.0 published 2024-10-16)

# ---------------------------------------------------------------------------
# 1. NVIDIA GPU Operator
# ---------------------------------------------------------------------------
resource "helm_release" "gpu_operator" {
  name             = "gpu-operator"
  repository       = "https://helm.ngc.nvidia.com/nvidia"
  chart            = "gpu-operator"
  version          = "v25.10.1"
  namespace        = "gpu-operator"
  create_namespace = true

  # Enable RDMA support in the driver component.
  # Values key confirmed: driver.rdma.enabled (helm show values gpu-operator v25.10.1)
  set {
    name  = "driver.rdma.enabled"
    value = "true"
  }

  # Use host MOFED when InfiniBand/EFA MOFED is pre-installed on the node.
  # On AWS EFA nodes the host EFA stack is used; set useHostMofed = true so the
  # driver component does not attempt to install its own MOFED.
  set {
    name  = "driver.rdma.useHostMofed"
    value = "true"
  }

  # Enable gdrcopy kernel module deployment.
  # Values key confirmed: gdrcopy.enabled (helm show values gpu-operator v25.10.1)
  set {
    name  = "gdrcopy.enabled"
    value = "true"
  }

  # Do not install the driver on nodes that already have a pre-installed driver
  # (e.g. Capacity Block AL2023 GPU AMIs ship with the NVIDIA driver).
  set {
    name  = "driver.enabled"
    value = tostring(var.gpu_operator_install_driver)
  }

  # Tolerate the standard GPU/EFA taints so operator pods land on GPU nodes.
  set {
    name  = "operator.tolerations[0].key"
    value = "nvidia.com/gpu"
  }
  set {
    name  = "operator.tolerations[0].operator"
    value = "Exists"
  }
  set {
    name  = "operator.tolerations[0].effect"
    value = "NoSchedule"
  }
  set {
    name  = "operator.tolerations[1].key"
    value = "vpc.amazonaws.com/efa"
  }
  set {
    name  = "operator.tolerations[1].operator"
    value = "Exists"
  }
  set {
    name  = "operator.tolerations[1].effect"
    value = "NoSchedule"
  }

  depends_on = [helm_release.karpenter]
}

# ---------------------------------------------------------------------------
# 2. AWS EFA k8s Device Plugin
# ---------------------------------------------------------------------------
resource "helm_release" "aws_efa_k8s_device_plugin" {
  name             = "aws-efa-k8s-device-plugin"
  repository       = "https://aws.github.io/eks-charts"
  chart            = "aws-efa-k8s-device-plugin"
  version          = "v0.5.29" # appVersion v0.5.20; chart version confirmed via helm search
  namespace        = "kube-system"
  create_namespace = false

  # The default supportedInstanceLabels already includes p5en.48xlarge and p5.48xlarge.
  # No overrides needed for standard GPU instances.

  # Tolerate the capacity-reservation taint (value varies per CB; use Exists).
  set {
    name  = "tolerations[0].key"
    value = "capacity-reservation"
  }
  set {
    name  = "tolerations[0].operator"
    value = "Exists"
  }
  set {
    name  = "tolerations[0].effect"
    value = "NoSchedule"
  }

  depends_on = [helm_release.gpu_operator]
}

# ---------------------------------------------------------------------------
# 3. MPI Operator v0.6.0
#    Deployed via kubectl_manifest from the official upstream single-file YAML.
#    URL confirmed: HTTP 200 for
#    https://raw.githubusercontent.com/kubeflow/mpi-operator/v0.6.0/deploy/v2beta1/mpi-operator.yaml
#
#    The gavinbunney/kubectl provider's kubectl_file_documents data source splits
#    a multi-document YAML into individual documents, filtering out empty entries.
# ---------------------------------------------------------------------------
data "http" "mpi_operator_manifest" {
  url = "https://raw.githubusercontent.com/kubeflow/mpi-operator/v0.6.0/deploy/v2beta1/mpi-operator.yaml"
}

data "kubectl_file_documents" "mpi_operator" {
  content = data.http.mpi_operator_manifest.response_body
}

resource "kubectl_manifest" "mpi_operator" {
  for_each  = data.kubectl_file_documents.mpi_operator.manifests
  yaml_body = each.value

  # Ignore updates to fields managed by the operator's own controllers.
  ignore_fields = ["metadata.annotations"]

  depends_on = [helm_release.gpu_operator]
}

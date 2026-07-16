# neuron-addons.tf
# Neuron (Trainium/Inferentia) Kubernetes add-on — the counterpart to gpu-addons.tf.
#
# Installs the official neuron-helm-chart, which bundles the Neuron device plugin
# (DaemonSet, advertises the `aws.amazon.com/neuron` resource) and, optionally, the
# Neuron Scheduler Extension. Activates only when at least one accelerator pool has
# device_plugin = "neuron" (local.has_neuron_pool), so a GPU-only cluster installs nothing.
#
# Verified facts:
#   - Chart: oci://public.ecr.aws/neuron/neuron-helm-chart  (name "neuron-helm-chart",
#     appVersion tracks the chart version; 1.9.0 verified present in ECR Public).
#   - The Neuron AL2023 EKS AMI ships the Neuron driver (aws-neuronx-dkms) and tools, so
#     no driver install is needed here — only the device plugin.
#   - npd (Node Problem Detector) is disabled: Karpenter + Neuron NPD/DRA is unsupported.
#   - Neuron nodes are tainted aws.amazon.com/neuron=true:NoSchedule by the plugin; serving
#     pods must tolerate it (see manifests/neuron-serving-vllm.yaml.tpl).
#   - Pods request whole Neuron devices via resources: aws.amazon.com/neuron: "<n>"
#     (trn2.48xlarge exposes 16). The Scheduler Extension (var.neuron_enable_scheduler)
#     guarantees contiguous device IDs for multi-device tensor-parallel serving.

locals {
  # Neuron device plugin should tolerate the accelerator + Capacity Block taints so it can
  # run on Neuron nodes. (The chart sets sane defaults; these are made explicit here.)
  neuron_helm_values = {
    # DRA and Node Problem Detector are unsupported alongside Karpenter — keep off.
    npd = { enabled = false }

    # Neuron Scheduler Extension: required for multi-device (tensor-parallel) pods so that
    # contiguous NeuronCore/device IDs are allocated. Toggled by var.neuron_enable_scheduler.
    scheduler = { enabled = var.neuron_enable_scheduler }

    # Device plugin tolerations: run on Neuron nodes and on Capacity Block reserved nodes.
    devicePlugin = {
      tolerations = [
        { key = "aws.amazon.com/neuron", operator = "Exists", effect = "NoSchedule" },
        { key = "capacity-reservation", operator = "Exists", effect = "NoSchedule" },
      ]
    }
  }
}

resource "helm_release" "neuron" {
  count = local.has_neuron_pool ? 1 : 0

  name             = "neuron-helm-chart"
  repository       = "oci://public.ecr.aws/neuron"
  chart            = "neuron-helm-chart"
  version          = var.neuron_helm_chart_version
  namespace        = "kube-system"
  create_namespace = false

  values = [yamlencode(local.neuron_helm_values)]

  # Needs the cluster and Karpenter CRDs/controller present; the plugin lands on Neuron
  # nodes once Karpenter provisions them. For destroy ordering, see the identical comment
  # on helm_release.gpu_operator in gpu-addons.tf — null_resource.wait_for_node_drain
  # (karpenter.tf) depends_on this release the same way.
  depends_on = [helm_release.karpenter]
}

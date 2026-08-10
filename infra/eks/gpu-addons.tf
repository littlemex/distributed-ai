# gpu-addons.tf
# GPU-related Kubernetes add-ons. Each activates based on the accelerator pools present:
#   1. NVIDIA GPU Operator      (var.gpu_operator_chart_version) — only if a GPU pool exists
#   2. AWS EFA k8s Device Plugin (var.efa_device_plugin_chart_version) — if any pool uses EFA
#      (shared by GPU and Neuron pools; trn2/p5/p5en/g6e all surface EFA via this plugin)
# The Neuron device plugin is a separate add-on (neuron-addons.tf); the multi-node training
# launcher is Kubeflow Trainer v2 (trainer.tf), which replaced the old Training Operator v1.
#
# Verified facts:
#   - gpu-operator chart from helm.ngc.nvidia.com/nvidia. Top-level values keys confirmed
#     via `helm show values`: driver.enabled, driver.rdma.enabled, driver.rdma.useHostMofed,
#     gdrcopy.enabled, operator.tolerations.
#   - aws-efa-k8s-device-plugin chart from aws.github.io/eks-charts. The chart version
#     differs from the app/image version; p5en.48xlarge/p5.48xlarge are in the default
#     supportedInstanceLabels list. (g6e.12xlarge is NOT — see the EFA gotcha in the
#     README/blog; on g6e the plugin still advertises EFA once an efa-only ENI exists.)
#   - The multi-node training launcher moved out of this file: Kubeflow Trainer v2 (TrainJob)
#     is installed by trainer.tf, replacing the vendored Training Operator v1 manifest that
#     used to live here.

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
  # harmlessly. capacity-reservation (value varies per CB) uses operator: Exists. The
  # module-owned taints are listed here; user pool taints come from the shared ledger
  # (local.user_taint_tolerations) so a tenant taint pool never strands the operands.
  gpu_operator_tolerations = concat([
    { key = "nvidia.com/gpu", operator = "Exists", effect = "NoSchedule" },
    { key = "vpc.amazonaws.com/efa", operator = "Exists", effect = "NoSchedule" },
    { key = "capacity-reservation", operator = "Exists", effect = "NoSchedule" },
  ], local.user_taint_tolerations)

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
      # NOTE: do NOT enable the operator's standalone DCGM (dcgm.enabled) for the
      # Node Monitoring Agent. The NMA bundles its OWN nv-hostengine as a
      # `dcgm-server` DaemonSet that binds hostPort 5555; AWS docs state you
      # cannot use an existing DCGM installation with the NMA. The operator's
      # standalone DCGM also binds hostPort 5555, so the two DaemonSets fight over
      # that port and whichever lands second stays Pending, leaving
      # AcceleratedHardwareReady stuck False (verified live). Leaving dcgm disabled
      # keeps dcgm-exporter in its default EMBEDDED mode (own DCGM, containerPort
      # 9400, no hostPort), which coexists cleanly with the NMA's dcgm-server.
      # DCGM ServiceMonitor is emitted by observability.tf (kubectl_manifest.dcgm_servicemonitor),
      # NOT by the operator. The operator's built-in SM cannot relabel node labels, so it cannot
      # stamp the karpenter-tenant-pools `tenant` label onto GPU metrics. observability.tf's
      # self-managed SM uses attachMetadata(node)=true + relabeling for that. Keep this false to
      # avoid a duplicate scrape of the same DCGM endpoint.
      dcgmExporter = {
        serviceMonitor = { enabled = false }
      }
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
  # keep the plugin off trn2 nodes, so vpc.amazonaws.com/efa is never advertised there. User pool
  # taints come from the shared ledger so an EFA pool with a tenant taint is not stranded either.
  efa_device_plugin_values = merge(
    {
      tolerations = concat([
        { key = "capacity-reservation", operator = "Exists", effect = "NoSchedule" },
        { key = "nvidia.com/gpu", operator = "Exists", effect = "NoSchedule" },
        { key = "aws.amazon.com/neuron", operator = "Exists", effect = "NoSchedule" },
      ], local.user_taint_tolerations)
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
  #
  # kube_prometheus_stack dependency: observability.tf's self-managed DCGM ServiceMonitor
  # needs the servicemonitors CRD (installed by kps) present before it is applied. Ordering
  # the operator AFTER kps gives create order "monitoring -> GPU" (CRD ready first) and, on
  # destroy, "GPU -> monitoring". Note the destroy edge is about resource ordering, not CRD
  # lifetime: kps keeps its CRDs under crds/, which `helm uninstall` does NOT delete, so the
  # servicemonitors CRD survives an observability teardown regardless (a known kps behavior —
  # the CRDs are left behind and, if unwanted, must be removed manually). When
  # enable_observability=false the referenced resource has count=0 (empty), so the dependency
  # is simply inert.
  depends_on = [
    helm_release.karpenter,
    helm_release.kube_prometheus_stack,
  ]
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
# 3. gdrdrv-loader DaemonSet — only when var.gdrcopy_mode == "daemonset".
#
#    FALLBACK path, not the recommended one. Prefer var.gdrcopy_mode = "userdata":
#    it is declarative, keeps no standing privileged pod, and lets the rpm's
#    gdrcopy.service own reboot persistence. This DaemonSet exists only for the case
#    where you cannot recycle nodes to pick up a userData change and must load gdrdrv
#    on already-running GPU nodes. It was verified end-to-end on a live node.
#
#    It installs AL2023's gdrcopy-kmod (dkms) and loads gdrdrv on GPU nodes whose driver
#    is preinstalled in the AMI (so the GPU Operator's own gdrcopy sidecar cannot run).
#    A container's own dnf cannot insert a module into the host kernel, so the install
#    chroots into the host. To keep the standing attack surface small, that privileged,
#    host-root-mounting work runs ONLY in an initContainer that exits once gdrdrv is
#    loaded; the long-running pod is an unprivileged `pause` with no host mounts (the
#    kernel module persists in the host independently of this pod). gdrcopy is a
#    small-message latency optimization; the bulk GPUDirect RDMA path does not need it.
resource "kubectl_manifest" "gdrdrv_loader" {
  count = var.gdrcopy_mode == "daemonset" && local.has_gpu_pool ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "DaemonSet"
    metadata = {
      name      = "gdrdrv-loader"
      namespace = "kube-system"
      labels    = { app = "gdrdrv-loader" }
    }
    spec = {
      selector = { matchLabels = { app = "gdrdrv-loader" } }
      template = {
        metadata = { labels = { app = "gdrdrv-loader" } }
        spec = {
          # nvidia.com/gpu.present is set by the GPU Operator's node-feature-discovery
          # once a node is up; the loader lands only on GPU nodes.
          nodeSelector      = { "nvidia.com/gpu.present" = "true" }
          priorityClassName = "system-node-critical"
          # Reuse the GPU Operator toleration set (module taints + user-taint ledger)
          # so the loader lands on exactly the same GPU nodes the operands do — no
          # separate hand-maintained copy that could drift out of sync.
          tolerations = local.gpu_operator_tolerations
          # Privileged, host-root work is confined to the initContainer. It exits after
          # loading gdrdrv; if it fails the pod restarts (kubelet backoff) and retries —
          # a fail-closed retry loop, unlike the userData path's fail-open install (the
          # asymmetry is intentional: on an already-running node we WANT to keep retrying).
          initContainers = [{
            name            = "load-gdrdrv"
            image           = var.gdrcopy_loader_image
            securityContext = { privileged = true }
            command = ["/bin/bash", "-c", <<-EOSH
              # No `set -e`: each step is checked explicitly.
              # Install the package if needed, then load via the rpm's own init script
              # `/usr/libexec/gdrcopy/gdrcopy start`. That script does modprobe + mknod of
              # /dev/gdrdrv and needs NO systemd bus, so it works from this container even
              # without hostPID (a chroot `systemctl --now` would fail with "Failed to connect
              # to bus"). It also fixes the "module loaded but device node missing" state that
              # a bare `lsmod` check would skip. We additionally `systemctl enable` (no --now)
              # best-effort for reboot persistence; if the enable can't reach the bus it is
              # harmless (the package auto-enables the unit at install time anyway).
              chroot /host bash -c 'rpm -q gdrcopy-kmod >/dev/null 2>&1 || dnf install -y gdrcopy-kmod'
              chroot /host /usr/libexec/gdrcopy/gdrcopy start || true
              chroot /host systemctl enable gdrcopy.service 2>/dev/null || true
              # Verify the end state for real: require the module AND the device node, else exit
              # non-zero so the pod restarts and retries rather than reporting success on a node
              # with no /dev/gdrdrv.
              if chroot /host bash -c 'lsmod | grep -q "^gdrdrv" && test -e /dev/gdrdrv'; then
                chroot /host ls -l /dev/gdrdrv
                echo "[gdrdrv-loader] verified: gdrdrv loaded, /dev/gdrdrv present"
              else
                echo "[gdrdrv-loader] gdrdrv not loaded or /dev/gdrdrv missing; retrying" >&2
                exit 1
              fi
            EOSH
            ]
            volumeMounts = [{ name = "host", mountPath = "/host" }]
            resources = {
              requests = { cpu = "10m", memory = "32Mi" }
              limits   = { cpu = "200m", memory = "256Mi" }
            }
          }]
          # Unprivileged idle main: keeps the DaemonSet pod Running (so its status reflects
          # "gdrdrv loaded on this node") without holding privilege or host mounts.
          containers = [{
            name    = "pause"
            image   = var.gdrcopy_loader_image
            command = ["/bin/bash", "-c", "trap 'exit 0' TERM; while true; do sleep 3600 & wait $!; done"]
            securityContext = {
              allowPrivilegeEscalation = false
              readOnlyRootFilesystem   = true
              runAsNonRoot             = true
              runAsUser                = 65534
              capabilities             = { drop = ["ALL"] }
            }
            resources = {
              requests = { cpu = "10m", memory = "16Mi" }
              limits   = { cpu = "50m", memory = "64Mi" }
            }
          }]
          volumes = [{ name = "host", hostPath = { path = "/" } }]
        }
      }
    }
  })

  depends_on = [helm_release.gpu_operator]
}

# Note: the "single gdrdrv loader" exclusivity is enforced as a hard plan-time error by a
# cross-variable validation on var.gdrcopy_mode (variables.tf), not a `check` block here —
# a `check` assert only warns and would still let a two-loader apply through.

###############################################################################
# observability.tf
# kube-prometheus-stack (Prometheus Operator + Grafana + kube-state-metrics +
# node-exporter) with GPU metrics from the DCGM exporter, sliced per tenant.
#
# Default ON (var.enable_observability = true). Terraform-managed, not a manual
# helm install: enabling it is a plain `terraform apply`.
#
# Placement (docs/node-role-separation.md): the monitoring stack runs on its
# OWN Karpenter NodePool (node-role=monitoring, defined below), NOT the system
# managed nodegroup. system is a sanctuary for kube-system + Karpenter
# controller only; a stateful Prometheus (2-4Gi RAM + 50Gi PVC) does not belong
# there and would break the moment the sanctuary taint is enabled. It is also
# NOT the shared cpu pool: that pool's consolidateAfter=30s reaped the node the
# instant the helm admission Job finished, wedging the release at
# pending-install. A dedicated WhenEmpty pool (consolidateAfter=10m) reclaims a
# node only once it is truly empty, so the idle gap between the hook Job and the
# main pods never triggers a reclaim — expressing "resident tier" structurally
# instead of via a do-not-disrupt annotation (which only guards a Running Pod).
#
# Apply/destroy order:
#   monitoring Namespace (kubectl) -> grafana-admin Secret (kubectl)
#     -> helm_release.kube_prometheus_stack (installs CRDs)
#       -> dcgm ServiceMonitor / dashboard ConfigMap (kubectl, need the CRD)
#   gpu-addons.tf's gpu_operator depends_on this release so create is
#   "monitoring -> GPU" and destroy is "GPU -> monitoring" (the DCGM SM CRD
#   must outlive the ServiceMonitor).
###############################################################################

locals {
  # Emit the self-managed DCGM ServiceMonitor only when observability AND a GPU
  # pool both exist; otherwise the CRD or the DCGM Service would be absent.
  dcgm_sm_enabled = var.enable_observability && local.has_gpu_pool

  observability_namespace = "monitoring"

  # Prometheus/Grafana size their TSDB cap from the PVC unless overridden: derive
  # ~90% of prometheus_storage_size so raising the PVC does not silently leave the
  # retention cap behind. (Gi -> GB is close enough for a soft cap.)
  prometheus_retention_size = coalesce(
    var.prometheus_retention_size,
    format("%dGB", floor(tonumber(trimsuffix(var.prometheus_storage_size, "Gi")) * 0.9)),
  )

  # The karpenter-tenant-pools node label in its Prometheus meta-label form.
  # Prometheus sanitizes any character outside [a-zA-Z0-9_] to '_' when exposing
  # node labels as __meta_kubernetes_node_label_*; derive that form (regex, not a
  # ./ -only replace) so any label key — including one with hyphens — keeps the
  # relabeling correct instead of silently producing a blank tenant label.
  tenant_meta_label = "__meta_kubernetes_node_label_${replace(var.tenant_node_label_key, "/[^a-zA-Z0-9_]/", "_")}"

  # node-role-separation.md: monitoring is a general CPU workload, not a
  # cluster-recovery prerequisite, so it does NOT go on the system sanctuary.
  # It gets its own Karpenter NodePool (node-role=monitoring, below) rather than
  # riding the shared cpu pool. Reason (observed live): the cpu pool's
  # consolidateAfter=30s reaps the node the instant the helm admission-webhook
  # Job finishes, before the main Prometheus/Grafana pods are scheduled, and the
  # release wedges at pending-install. karpenter.sh/do-not-disrupt cannot fix
  # that — a Pod annotation only protects a node while the Pod is Running, so it
  # is blind to the idle gap between a Succeeded hook Job and the main pods.
  # A dedicated WhenEmpty pool expresses "this tier is resident" structurally.
  observability_node_selector = {
    "node-role" = "monitoring"
  }

  kps_values = {
    # Short, deterministic resource names (kps-prometheus / kps-grafana) so the
    # port-forward one-liners in outputs.tf stay stable.
    fullnameOverride                   = "kps"
    cleanPrometheusOperatorObjectNames = true

    prometheus = {
      prometheusSpec = {
        retention     = var.prometheus_retention        # "15d"
        retentionSize = local.prometheus_retention_size # derived ~90% of the PVC unless overridden

        # release-label discovery: pick up only ServiceMonitors carrying this
        # chart's release label (release=kps). Self-managed SMs must set it (see
        # the DCGM SM below). Namespace selector is empty so SMs in gpu-operator
        # ns are still discovered as long as they carry release=kps.
        serviceMonitorSelectorNilUsesHelmValues = true
        serviceMonitorNamespaceSelector         = {}
        podMonitorNamespaceSelector             = {}

        nodeSelector = local.observability_node_selector

        # storageSpec.volumeClaimTemplate.spec is a 3-level nest; omitting `spec`
        # silently yields an emptyDir instead of a PVC.
        storageSpec = {
          volumeClaimTemplate = {
            spec = {
              storageClassName = var.observability_storage_class # "gp3"
              accessModes      = ["ReadWriteOnce"]
              resources = {
                requests = {
                  storage = var.prometheus_storage_size # "50Gi"
                }
              }
            }
          }
        }

        resources = {
          requests = { cpu = "500m", memory = "2Gi" }
          limits   = { memory = "4Gi" }
        }
      }
    }

    grafana = {
      # admin.existingSecret keeps the password out of the Helm release values.
      admin = {
        existingSecret = "grafana-admin"
        userKey        = "admin-user"
        passwordKey    = "admin-password"
      }

      defaultDashboardsEnabled = true

      persistence = {
        enabled          = true
        storageClassName = var.observability_storage_class
        size             = var.grafana_storage_size # "10Gi"
      }

      nodeSelector = local.observability_node_selector

      sidecar = {
        dashboards = {
          enabled         = true
          label           = "grafana_dashboard"
          labelValue      = "1"
          searchNamespace = "ALL"
          # folderAnnotation only takes effect with foldersFromFilesStructure.
          folderAnnotation = "grafana_folder"
          provider = {
            foldersFromFilesStructure = true
          }
        }
      }

      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { memory = "512Mi" }
      }
    }

    prometheusOperator = {
      # Stateless: nodeSelector only, no do-not-disrupt.
      nodeSelector = local.observability_node_selector

      # Admission webhook disabled. It ships as a helm pre-install hook
      # (kube-webhook-certgen Job with hook-delete-policy=before-hook-creation);
      # under helm v4 that hook's delete-wait never resolves ("waiting for
      # resources to be deleted count=1" on a not-found ServiceAccount), so the
      # release wedges at pending-install and `terraform apply` times out.
      # Verified live: enabled=false makes the install complete cleanly.
      #
      # What is lost is only apply-time fail-fast on malformed PrometheusRule/
      # AlertmanagerConfig. It is NOT a correctness risk here: CRD structural
      # schema validation still runs at the apiserver, and Prometheus Operator
      # re-validates rules at reconcile and drops a bad one without breaking the
      # shared config reload — a bad tenant rule cannot take down the stack.
      # CI (`promtool check rules`) covers the fast-feedback gap. When a real
      # tenant rule-submission flow is introduced, re-enable via
      # admissionWebhooks.certManager.enabled=true (that path emits no certgen
      # hook Job, so it sidesteps the helm v4 wedge).
      admissionWebhooks = {
        enabled = false
      }
      tls = {
        enabled = false
      }

      resources = {
        requests = { cpu = "100m", memory = "128Mi" }
        limits   = { memory = "256Mi" }
      }
    }

    # subchart keys keep their hyphenated names (quoted in HCL).
    "kube-state-metrics" = {
      nodeSelector = local.observability_node_selector
    }

    # node-exporter is a DaemonSet and must land on every node, including
    # accelerator nodes with taints (nvidia.com/gpu, aws.amazon.com/neuron,
    # capacity-reservation, tenantpools.dev/tenant). operator: Exists with no
    # key tolerates every taint.
    "prometheus-node-exporter" = {
      tolerations = [
        {
          operator = "Exists"
        }
      ]
    }

    # alertmanager off: with no routing target (Slack/PagerDuty) configured it
    # would just drop notifications. Enable later with enabled=true + config.
    alertmanager = {
      enabled = false
    }
  }
}

# --- gp3 StorageClass (EBS CSI) ----------------------------------------------
# The Prometheus/Grafana PVCs need a StorageClass. Verified live: this cluster
# ships only the in-tree `gp2` default (provisioner kubernetes.io/aws-ebs); no
# EBS CSI gp3 class exists. Create a non-default gp3 class here (cheaper + faster
# than gp2, and CSI rather than the deprecated in-tree provisioner) that the
# monitoring PVCs reference explicitly via var.observability_storage_class.
# volumeBindingMode=WaitForFirstConsumer so the volume is created in the AZ the
# pod actually lands on (Karpenter is topology-aware and starts the monitoring
# node in that AZ), avoiding the "PVC bound to an AZ with no node" trap.
#
# Gated by observability_storage_class_create: set it false to point the PVCs at
# a pre-existing StorageClass of the same name instead. Do not create a class
# whose name already exists — StorageClass parameters are immutable and the
# apply would fail. Note the created class carries a cluster-generic name
# (gp3); if other workloads adopt it, disabling observability removes it too.
resource "kubectl_manifest" "observability_storage_class" {
  count = var.enable_observability && var.observability_storage_class_create ? 1 : 0

  yaml_body = yamlencode({
    apiVersion  = "storage.k8s.io/v1"
    kind        = "StorageClass"
    metadata    = { name = var.observability_storage_class }
    provisioner = "ebs.csi.aws.com"
    parameters = {
      type      = "gp3"
      encrypted = "true"
    }
    reclaimPolicy        = "Delete"
    volumeBindingMode    = "WaitForFirstConsumer"
    allowVolumeExpansion = true
  })

  # This class names the ebs.csi.aws.com provisioner, installed as the
  # aws-ebs-csi-driver addon inside module.eks; wait for the cluster/addons.
  # (The other observability resources reach the cluster through the kubectl
  # provider's implicit dependency, so only this CSI-tied one needs the edge.)
  depends_on = [module.eks]
}

# --- dedicated monitoring NodePool + EC2NodeClass ----------------------------
# The monitoring stack is a resident stateful tier. Expressing that with a
# WhenEmpty NodePool (not the shared cpu pool's WhenEmptyOrUnderutilized /
# consolidateAfter=30s) is what actually protects it: a WhenEmpty node is only
# reclaimed once it holds NO pods, so the idle gap between the helm admission
# Job finishing and the main pods scheduling never triggers a reclaim.
#
# Reuses local.nodeclass_common / local.cpu_user_data (defined in
# karpenter-resources.tf) so subnet/SG/instanceProfile/image-pull tuning stay
# identical to the other pools. This is an implementation detail of the
# observability feature, driven by enable_observability alone — it is NOT part
# of the user-facing accelerator_pools variable.
resource "kubectl_manifest" "ec2nodeclass_monitoring" {
  count = var.enable_observability ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata   = { name = "monitoring" }
    # Shared with the cpu NodeClass (karpenter-resources.tf) via this local, so
    # AMI/disk/image-pull tuning is defined once for both CPU-class pools.
    spec = local.general_cpu_nodeclass_spec
  })

  # See nodepool_monitoring below for why null_resource.wait_for_node_drain is
  # intentionally not in this depends_on (it would form a dependency cycle).
  depends_on = [helm_release.karpenter]
}

resource "kubectl_manifest" "nodepool_monitoring" {
  count = var.enable_observability ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata   = { name = "monitoring" }
    spec = {
      template = {
        # Same local the stack's nodeSelector uses, so the pool label and the
        # selector cannot drift (a mismatch would leave every pod Pending).
        metadata = { labels = local.observability_node_selector }
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "monitoring"
          }
          requirements = [
            # on-demand only: never put the Prometheus TSDB on a spot node that
            # can be reclaimed mid-write.
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = ["on-demand"]
            },
            {
              key      = "karpenter.k8s.aws/instance-category"
              operator = "In"
              values   = var.observability_instance_categories
            },
            {
              key      = "karpenter.k8s.aws/instance-generation"
              operator = "Gt"
              values   = ["4"]
            },
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = ["amd64"]
            },
            {
              key      = "kubernetes.io/os"
              operator = "In"
              values   = ["linux"]
            },
          ]
          expireAfter = "Never"
        }
      }
      # WhenEmpty (not WhenEmptyOrUnderutilized): reclaim only a truly empty node.
      # consolidateAfter=10m (not Never): if enable_observability is later turned
      # off, the drained node is cleaned up instead of lingering forever.
      # No taint: the node-role=monitoring nodeSelector on the stack, plus the
      # cpu-role selectors on other workloads, already keep foreign pods off; a
      # taint would just force tolerations onto all 4 components + the hook Jobs.
      disruption = {
        consolidationPolicy = "WhenEmpty"
        consolidateAfter    = "10m"
      }
      # Safety valve: cap the tier so a runaway never balloons the bill. This is
      # a ~1-2 node tier in practice.
      limits = {
        cpu    = "8"
        memory = "32Gi"
      }
    }
  })

  # No depends_on null_resource.wait_for_node_drain here (unlike the cpu/accelerator
  # NodePools): the drain-wait depends_on helm_release.gpu_operator, which in turn
  # depends_on helm_release.kube_prometheus_stack, which depends_on this NodePool —
  # adding that edge would form a cycle. The monitoring pool only ever hosts the
  # monitoring stack (no accelerator/CPU workloads drain through it), so it does
  # not need to participate in the drain-wait destroy ordering.
  depends_on = [kubectl_manifest.ec2nodeclass_monitoring]
}

# --- monitoring namespace ----------------------------------------------------
# Create the namespace in Terraform (not via helm create_namespace) so the
# grafana-admin Secret can be created BEFORE the Helm release.
#
# tenantpools.dev/excluded=true: the karpenter-tenant-pools ValidatingAdmission
# Policy (Experiment01) rejects any pod that tolerates a taint other than its
# own tenant's. The monitoring stack is infrastructure, not a tenant workload:
# node-exporter (DaemonSet) must tolerate EVERY taint to land on all nodes, and
# the helm hook pods carry a scheduler-set spec.nodeName that the VAP also
# rejects on UPDATE. Verified live: without this label node-exporter is denied
# and the install cannot converge. The label is a no-op when Experiment01 is
# not installed.
resource "kubectl_manifest" "monitoring_namespace" {
  count = var.enable_observability ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name = local.observability_namespace
      labels = {
        "tenantpools.dev/excluded" = "true"
      }
    }
  })
}

# --- Grafana admin credentials ----------------------------------------------
resource "random_password" "grafana_admin" {
  count   = var.enable_observability ? 1 : 0
  length  = 24
  special = false # safe to paste into a port-forward URL / CLI
}

resource "kubectl_manifest" "grafana_admin_secret" {
  count = var.enable_observability ? 1 : 0

  # stringData (not base64 data). sensitive_fields keeps it out of plan diffs;
  # it is still written to tfstate in cleartext (see README: state must be
  # encrypted with a least-privilege backend).
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    metadata = {
      name      = "grafana-admin"
      namespace = local.observability_namespace
    }
    type = "Opaque"
    stringData = {
      "admin-user"     = "admin"
      "admin-password" = random_password.grafana_admin[0].result
    }
  })

  sensitive_fields = ["stringData"]

  depends_on = [kubectl_manifest.monitoring_namespace]
}

# --- kube-prometheus-stack ---------------------------------------------------
resource "helm_release" "kube_prometheus_stack" {
  count = var.enable_observability ? 1 : 0

  name       = "kps"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.kube_prometheus_stack_version
  namespace  = local.observability_namespace

  create_namespace = false # namespace created above
  wait             = true
  timeout          = 900

  values = [yamlencode(local.kps_values)]

  depends_on = [
    kubectl_manifest.monitoring_namespace,
    kubectl_manifest.grafana_admin_secret, # Grafana needs the Secret at startup
    # The NodePool must exist before helm (wait=true) starts scheduling pods,
    # otherwise the admission Job / main pods have nowhere to land.
    kubectl_manifest.nodepool_monitoring,
    # The PVCs reference this StorageClass; it must exist before install.
    kubectl_manifest.observability_storage_class,
  ]
}

# --- DCGM ServiceMonitor (self-managed, tenant-stamped) ----------------------
# gpu-operator's own SM is disabled (gpu-addons.tf) because it cannot relabel
# node labels. attachMetadata.node=true exposes __meta_kubernetes_node_label_*
# to relabeling so the karpenter-tenant-pools node label becomes a `tenant`
# metric label at scrape time.
resource "kubectl_manifest" "dcgm_servicemonitor" {
  count = local.dcgm_sm_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "ServiceMonitor"
    metadata = {
      # Deliberately NOT named "nvidia-dcgm-exporter": that is the exact name the
      # GPU Operator uses for its own DCGM ServiceMonitor, and with
      # dcgmExporter.serviceMonitor.enabled=false the operator reconciles that
      # name to "should not exist" and DELETES any SM of that name on every
      # reconcile (verified live: our SM kept vanishing whenever a GPU node was
      # recycled and the operator re-reconciled). A distinct name keeps it out of
      # the operator's prune scope.
      name = "nvidia-dcgm-exporter-tenant"
      # Same namespace the GPU Operator (gpu-addons.tf) installs into, derived
      # from that release so the two cannot drift apart. dcgm_sm_enabled implies
      # has_gpu_pool, so gpu_operator[0] always exists here.
      namespace = helm_release.gpu_operator[0].namespace
      labels = {
        # Must match the kps release name so Prometheus' release-label selector
        # discovers this SM; derived from the release so a rename cannot silently
        # break scraping. dcgm_sm_enabled implies enable_observability, so [0] exists.
        release = helm_release.kube_prometheus_stack[0].name
      }
    }
    spec = {
      selector = {
        matchLabels = {
          app = "nvidia-dcgm-exporter" # verified live: Service label
        }
      }
      attachMetadata = {
        node = true
      }
      endpoints = [
        {
          port     = "gpu-metrics" # verified live: port name (9400)
          interval = "30s"
          relabelings = [
            {
              # The tenant node label (var.tenant_node_label_key) surfaces as
              # local.tenant_meta_label after Prometheus sanitizes '.' and '/'
              # to '_'; copy it to the `tenant` metric label.
              action       = "replace"
              sourceLabels = [local.tenant_meta_label]
              targetLabel  = "tenant"
            },
            {
              action       = "replace"
              sourceLabels = ["__meta_kubernetes_node_name"]
              targetLabel  = "node"
            },
          ]
        }
      ]
    }
  })

  # CRD (servicemonitors.monitoring.coreos.com) comes from kps; the DCGM Service
  # comes from gpu-operator. Wait for both.
  depends_on = [
    helm_release.kube_prometheus_stack,
    helm_release.gpu_operator,
  ]
}

# --- GPU per-tenant dashboard (picked up by the Grafana sidecar) ------------
resource "kubectl_manifest" "dashboard_gpu_tenant" {
  count = local.dcgm_sm_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata = {
      name      = "grafana-dashboard-gpu-tenant"
      namespace = local.observability_namespace
      labels = {
        grafana_dashboard = "1" # matches sidecar.dashboards.label / labelValue
      }
      annotations = {
        grafana_folder = "GPU" # matches folderAnnotation
      }
    }
    data = {
      "gpu-tenant.json" = file("${path.module}/dashboards/gpu-tenant.json")
    }
  })

  depends_on = [helm_release.kube_prometheus_stack]
}

# --- Community dashboards (picked up by the Grafana sidecar) -----------------
# Curated Grafana.com dashboards whose metrics actually exist in this stack:
#   - Node Exporter Full (grafana.com id 1860): node CPU/mem/disk/network from
#     the kube-prometheus-stack node-exporter (always present).
#   - NVIDIA DCGM Exporter Dashboard (grafana.com id 12239): GPU utilization/
#     memory/temp/power from the GPU Operator's dcgm-exporter (GPU pools only).
# The JSON was normalized for sidecar import: __inputs stripped and datasource
# references pinned to the kps Prometheus (uid "prometheus"). EFA and FSx
# dashboards are intentionally NOT included — no exporter emits those metrics on
# this cluster yet, so their panels would be empty (see the book chapter).
resource "kubectl_manifest" "dashboard_node_exporter" {
  count = var.enable_observability ? 1 : 0

  # Node Exporter Full is a large dashboard (~460KB). Use server-side apply so
  # the provider does NOT stuff the whole body into the
  # kubectl.kubernetes.io/last-applied-configuration annotation, which is capped
  # at 262144 bytes and would otherwise fail this ConfigMap.
  server_side_apply = true
  force_conflicts   = true

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata = {
      name      = "grafana-dashboard-node-exporter-full"
      namespace = local.observability_namespace
      labels    = { grafana_dashboard = "1" }
      annotations = {
        grafana_folder = "Nodes"
      }
    }
    data = {
      "node-exporter-full.json" = file("${path.module}/dashboards/node-exporter-full.json")
    }
  })

  depends_on = [helm_release.kube_prometheus_stack]
}

resource "kubectl_manifest" "dashboard_dcgm_exporter" {
  count = local.dcgm_sm_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata = {
      name      = "grafana-dashboard-dcgm-exporter"
      namespace = local.observability_namespace
      labels    = { grafana_dashboard = "1" }
      annotations = {
        grafana_folder = "GPU"
      }
    }
    data = {
      "dcgm-exporter.json" = file("${path.module}/dashboards/dcgm-exporter.json")
    }
  })

  depends_on = [helm_release.kube_prometheus_stack]
}

# --- Node Monitoring Agent (detection only) ----------------------------------
# EKS Node Monitoring Agent: emits NodeConditions for kernel / container-runtime
# / networking / storage / accelerated-hardware faults. GPU faults come through
# a bundled DCGM nv-hostengine (XID, double-bit ECC, NVLink/NVSwitch); this is a
# health *signal*, distinct from the GPU Operator's DCGM exporter (metrics).
#
# Detection only: Karpenter node auto-repair (the NodeRepair feature gate, which
# would terminate an unhealthy node) is intentionally NOT enabled. On a Capacity
# Block cluster running tightly-coupled training, an auto-terminate can churn a
# still-diagnosable, pre-paid GPU node and even re-draw the same faulty host from
# the reservation. Instead the NodeConditions surface via kube-state-metrics into
# the Prometheus/Grafana stack above for alerting, and the decision to drain or
# replace stays with the job layer / an operator. See the reasoning in the blog
# post referenced by the observability book chapter.
#
# Installed as an EKS managed add-on (aws_eks_addon), matching how the other
# AWS-provided add-ons in this module are managed (EBS/EFS/FSx CSI etc.): EKS
# tracks K8s-version compatibility, surfaces version/health in the console, and
# is the supported install path.
#
# The one non-default setting is the dcgm-server toleration. The agent's bundled
# `dcgm-server` DaemonSet (the nv-hostengine that reads GPU health) ships with NO
# tolerations, so on this cluster's GPU pools (nvidia.com/gpu:NoSchedule taint)
# it cannot land on any GPU node and AcceleratedHardwareReady stays stuck False —
# a detection gap exactly on the nodes that matter (verified live). The add-on
# exposes dcgmAgent.tolerations in its configurationValues schema (v1.3.0+), so
# we grant the GPU toleration there. Scoped to nvidia.com/gpu (not a blanket
# Exists) so it never leaks onto unrelated tainted nodes. This looks like an
# upstream default oversight (the agent itself tolerates all taints, dcgm-server
# does not); if AWS fixes the default, this configuration_values block can be
# dropped.
resource "aws_eks_addon" "node_monitoring_agent" {
  count = var.enable_node_monitoring_agent ? 1 : 0

  cluster_name  = module.eks.cluster_name
  addon_name    = "eks-node-monitoring-agent"
  addon_version = var.node_monitoring_agent_version # null => EKS default for the K8s version

  configuration_values = jsonencode({
    dcgmAgent = {
      tolerations = [{
        key      = "nvidia.com/gpu"
        operator = "Exists"
        effect   = "NoSchedule"
      }]
    }
  })

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = {
    Environment = var.environment
    Project     = "distributed-ai"
  }
}

# --- Alerting rules for the Node Monitoring Agent's NodeConditions -----------
# Makes the "surface for alerting" intent real: without a rule the NodeConditions
# are only visible if someone opens a dashboard. These fire on the condition
# going False; with alertmanager disabled (kps_values) they still show in the
# Prometheus UI / Alerts, and enabling alertmanager later routes them with no
# further change. AcceleratedHardwareReady is critical (a GPU fault kills a
# tightly-coupled training job); the rest are warnings.
resource "kubectl_manifest" "node_health_alert_rules" {
  count = var.enable_node_monitoring_agent && var.enable_observability ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PrometheusRule"
    metadata = {
      name      = "node-monitoring-agent"
      namespace = local.observability_namespace
      # Derived from the kps release name so a rename cannot silently drop these
      # rules from Prometheus (a detection gap that itself would be unmonitored).
      labels = { release = helm_release.kube_prometheus_stack[0].name }
    }
    spec = {
      groups = [{
        name = "node-monitoring-agent"
        rules = [
          {
            alert = "AcceleratedHardwareUnhealthy"
            expr  = "kube_node_status_condition{condition=\"AcceleratedHardwareReady\",status=\"true\"} == 0"
            "for" = "2m"
            labels = {
              severity  = "critical"
              component = "node-monitoring-agent"
            }
            annotations = {
              summary     = "Accelerated hardware unhealthy on {{ $labels.node }}"
              description = "AcceleratedHardwareReady=False. Either a real GPU/accelerator fault (XID, ECC, NVLink) — in which case a tightly-coupled job on this node is likely hung, so let the job layer decide to drain/replace — OR the NMA's dcgm-server DaemonSet is down/unschedulable on this node (check `kubectl get ds dcgm-server -n kube-system` first, since that also pins the condition False)."
            }
          },
          {
            alert = "NodeConditionUnhealthy"
            expr  = "kube_node_status_condition{condition=~\"KernelReady|ContainerRuntimeReady|NetworkingReady|StorageReady\",status=\"true\"} == 0"
            "for" = "5m"
            labels = {
              severity  = "warning"
              component = "node-monitoring-agent"
            }
            annotations = {
              summary     = "{{ $labels.condition }} is False on {{ $labels.node }}"
              description = "The Node Monitoring Agent reports {{ $labels.condition }}=False for 5m."
            }
          },
          {
            # Self-monitor the detector. NodeConditions do not auto-expire, so if
            # the NMA agent (or dcgm-server) DaemonSet is down, its last reported
            # condition goes stale and the two alerts above fall silent — a blind
            # spot in a detection-only setup. Watch the DaemonSets themselves.
            alert = "NodeMonitoringAgentDown"
            expr  = "kube_daemonset_status_number_unavailable{namespace=\"kube-system\",daemonset=~\"eks-node-monitoring-agent|dcgm-server\"} > 0"
            "for" = "10m"
            labels = {
              severity  = "warning"
              component = "node-monitoring-agent"
            }
            annotations = {
              summary     = "Node monitoring DaemonSet {{ $labels.daemonset }} has unavailable pods"
              description = "{{ $labels.daemonset }} has unavailable pods for 10m; GPU/node health detection may be blind on the affected nodes."
            }
          },
        ]
      }]
    }
  })

  depends_on = [helm_release.kube_prometheus_stack]
}

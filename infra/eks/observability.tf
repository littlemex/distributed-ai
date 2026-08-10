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
# NOT the shared cpu pool: that pool's aggressive consolidation would reclaim the
# node out from under this resident stateful tier. It gets its own WhenEmpty
# NodePool instead; the full rationale lives at nodepool_monitoring below.
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

  # AZ the monitoring NodePool is pinned to (see the nodepool zone requirement).
  # Explicit var.observability_zone wins; otherwise the first cluster AZ.
  observability_zone = coalesce(var.observability_zone, local.azs[0])

  # Tolerations for the Node Monitoring Agent's bundled dcgm-server (reads GPU
  # health via nv-hostengine). It must land on every GPU node, which can carry the
  # module-owned nvidia.com/gpu device-plugin taint (karpenter-resources.tf), a
  # per-reservation `capacity-reservation` taint on Capacity Block nodes, AND any
  # user pool taints. Missing the CB taint leaves dcgm-server Pending on exactly the
  # pre-paid CB GPU nodes that matter most — and worse, keeps AcceleratedHardwareReady
  # False there, firing AcceleratedHardwareUnhealthy forever; a user taint pool has
  # the identical failure mode, so we pull those from the shared ledger. neuron is
  # omitted on purpose (dcgm-server reads NVIDIA GPUs only). Kept scoped (Exists per
  # known key, not a blanket toleration) so it never leaks onto unrelated tainted nodes.
  dcgm_server_tolerations = concat([
    { key = "nvidia.com/gpu", operator = "Exists", effect = "NoSchedule" },
    { key = "capacity-reservation", operator = "Exists", effect = "NoSchedule" },
  ], local.user_taint_tolerations)

  # Grafana dashboards shipped as sidecar-discovered ConfigMaps. Declaring them as
  # a map (rather than one resource each) keeps "which dashboard, which folder,
  # under which condition" in a single readable table and lets a single resource
  # render them all. Each key is both the ConfigMap suffix and the JSON basename
  # in dashboards/, so name/key/file agreement is structural, not convention.
  #   - gpu-tenant        : self-authored per-tenant GPU view (needs a GPU pool)
  #   - node-exporter-full: grafana.com id 1860 (always available)
  #   - dcgm-exporter     : grafana.com id 12239 (needs a GPU pool)
  # The community JSON was normalized for sidecar import: __inputs stripped and
  # datasource references pinned to the kps Prometheus (uid "prometheus") via
  # dashboards/normalize.py. EFA and FSx dashboards are intentionally excluded —
  # no exporter emits those metrics on this cluster yet (see the book chapter).
  grafana_dashboards = {
    "gpu-tenant" = {
      folder  = "GPU"
      enabled = local.dcgm_sm_enabled
    }
    "node-exporter-full" = {
      folder  = "Nodes"
      enabled = var.enable_observability
    }
    "dcgm-exporter" = {
      folder  = "GPU"
      enabled = local.dcgm_sm_enabled
    }
  }

  # Prometheus sizes its TSDB retention cap from the PVC unless overridden: derive
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
  # cluster-recovery prerequisite, so it does NOT go on the system sanctuary. It
  # gets its own Karpenter NodePool (node-role=monitoring, below) rather than
  # riding the shared cpu pool — see nodepool_monitoring for the full rationale.
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

        # Prometheus memory scales with active series; raise var.prometheus_resources
        # on large clusters to avoid an OOMKill crash-loop (see variable docs).
        resources = {
          requests = {
            cpu    = var.prometheus_resources.cpu_request
            memory = var.prometheus_resources.memory_request
          }
          limits = { memory = var.prometheus_resources.memory_limit }
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

      # Recreate (not the chart-default RollingUpdate): Grafana is a single-replica
      # Deployment on a ReadWriteOnce EBS PVC. RollingUpdate starts the new pod
      # before terminating the old one; if the new pod lands on a different node in
      # the monitoring pool, the EBS volume Multi-Attach fails and the new pod hangs
      # Pending, wedging the next `helm upgrade`. Recreate stops the old pod first so
      # the single RWO volume is always free for the new one.
      deploymentStrategy = {
        type = "Recreate"
      }

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
        datasources = {
          # Pin the auto-provisioned Prometheus datasource uid to "prometheus"
          # explicitly. The vendored dashboards reference this uid (see
          # dashboards/normalize.py); making it a value we set here — rather than
          # relying on the chart's implicit default — keeps that contract visible
          # in code, so a chart change to the default uid would surface as a diff.
          enabled                  = true
          defaultDatasourceEnabled = true
          uid                      = "prometheus"
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
# The monitoring stack is a resident stateful tier (Prometheus + Grafana on PVCs).
# It runs on this dedicated WhenEmpty NodePool rather than the shared cpu pool for
# two reasons:
#   1. Steady state: a WhenEmpty node is reclaimed only once it holds NO pods, so
#      a resident stateful tier is never consolidated out from under itself — the
#      way the shared cpu pool's WhenEmptyOrUnderutilized policy would. This
#      expresses "resident tier" structurally, not via a do-not-disrupt annotation
#      (which only guards a node while its Pod is Running).
#   2. Install time: when this stack was first brought up on the shared cpu pool,
#      that pool's short consolidateAfter reclaimed the freshly-launched node
#      during the gap between a helm pre-install hook Job finishing and the main
#      pods being scheduled, wedging the release at pending-install. (This module
#      now also disables the kps admission-webhook certgen hook — see
#      prometheusOperator.admissionWebhooks below — so that specific hook Job no
#      longer runs; the WhenEmpty pool removes the class of failure regardless.)
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

  # Fail at plan time if observability_zone is not a real cluster AZ. Otherwise a typo
  # renders a NodePool that can never launch a node, and the only symptom is the helm
  # release timing out after 900s with the monitoring pods stuck Pending.
  lifecycle {
    precondition {
      condition     = contains(local.azs, local.observability_zone)
      error_message = "observability_zone (${local.observability_zone}) is not one of the cluster AZs (${join(", ", local.azs)}). Set var.observability_zone to an AZ that has a subnet, or leave it null to use azs[0]."
    }
  }

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
            {
              # Pin the pool to a single AZ. Prometheus and Grafana hold ReadWriteOnce
              # EBS PVCs; an EBS volume is AZ-local. The StorageClass is
              # WaitForFirstConsumer so a PVC binds in whichever AZ the first node lands —
              # but if a later node (e.g. a Drift-driven AMI rollout) came up in a
              # different AZ, that AZ-locked PVC could not attach and the stack would hang
              # Pending with a volume node affinity conflict. Pinning the AZ makes every
              # monitoring node land where the PVCs already live. (The accelerator pools
              # pin AZ too, for EFA/CB reasons — see karpenter-resources.tf.) Defaults to
              # azs[0] (deterministic for a fresh deploy); var.observability_zone overrides
              # it when existing PVCs already live in another AZ — see the variable docs.
              key      = "topology.kubernetes.io/zone"
              operator = "In"
              values   = [local.observability_zone]
            },
          ]
          expireAfter = "Never"
        }
      }
      # WhenEmpty (not WhenEmptyOrUnderutilized): reclaim only a truly empty node,
      # never one that is merely underutilized — this tier is resident. consolidateAfter=10m
      # (not Never) still lets Karpenter reclaim a node that legitimately goes empty (a
      # transient scale-to-zero, or a rollout that briefly leaves the node bare) after a
      # 10m grace, rather than holding an idle on-demand node forever.
      #
      # No taint is a deliberate trade-off, not a guarantee of isolation. The
      # node-role=monitoring nodeSelector on the stack only pulls the monitoring
      # pods ONTO this pool; it does not stop a selector-less pod from being
      # bin-packed onto the node by kube-scheduler. In this cluster the other
      # workloads all carry their own node-role/accelerator selectors, so in
      # practice nothing foreign lands here — but if a truly unconstrained pod is
      # introduced it could co-locate and, by keeping the node non-empty, defer
      # WhenEmpty reclaim. If that becomes a real risk, add a node-role=monitoring
      # taint plus a matching toleration on all monitoring components. We skip it
      # today to avoid maintaining tolerations across every kps subchart.
      disruption = {
        consolidationPolicy = "WhenEmpty"
        consolidateAfter    = "10m"
        # Drift (e.g. an AMI/nodeclass change) disrupts nodes regardless of
        # consolidationPolicy. This tier is a single-replica stateful stack on an
        # AZ-locked EBS PVC, so an involuntary Drift replacement means a monitoring
        # outage while the volume re-attaches (and, if it re-attaches cleanly, only
        # because the AZ is now pinned above). Block Drift/underutilization-style
        # disruption entirely; still allow Emptiness so a truly empty node (e.g. after
        # enable_observability=false) is reclaimed. AMI updates then happen on our
        # terms (bump the nodeclass and let the node roll when we choose), not mid-scrape.
        budgets = [
          {
            nodes   = "0"
            reasons = ["Drifted", "Underutilized"]
          },
        ]
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
# This module owns the monitoring namespace. If a namespace of this name already
# exists on the cluster, Terraform adopts it and `enable_observability=false`
# (or destroy) will DELETE it along with anything else in it. The name is fixed
# rather than a variable because several relabelings, selectors, and the book
# chapters all reference "monitoring"; change it in one place only if you must.
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

# --- Grafana dashboards (picked up by the Grafana sidecar) -------------------
# One resource renders every dashboard declared in local.grafana_dashboards, so
# adding a dashboard is a one-line map entry plus its JSON in dashboards/. The
# ConfigMap name, the data key, and the source file all derive from each.key, so
# the three can never drift out of agreement.
#
# server_side_apply is on for all of them: the largest (node-exporter-full, ~460KB)
# would otherwise overflow the kubectl.kubernetes.io/last-applied-configuration
# annotation (capped at 262144 bytes); applying it uniformly avoids a per-size
# branch and keeps the apply behavior identical across dashboards. force_conflicts
# only takes field ownership from a prior client-side apply — the Grafana sidecar
# reads these ConfigMaps and never writes them, so there is no real contention.
resource "kubectl_manifest" "grafana_dashboard" {
  for_each = { for k, v in local.grafana_dashboards : k => v if v.enabled }

  server_side_apply = true
  force_conflicts   = true

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata = {
      name      = "grafana-dashboard-${each.key}"
      namespace = local.observability_namespace
      labels    = { grafana_dashboard = "1" } # matches sidecar.dashboards.label
      annotations = {
        grafana_folder = each.value.folder # matches sidecar folderAnnotation
      }
    }
    data = {
      "${each.key}.json" = file("${path.module}/dashboards/${each.key}.json")
    }
  })

  depends_on = [helm_release.kube_prometheus_stack]
}

# Migrate the three former per-dashboard resources into the for_each map in place
# (no destroy/recreate). Harmless to keep; can be dropped after one apply.
moved {
  from = kubectl_manifest.dashboard_gpu_tenant[0]
  to   = kubectl_manifest.grafana_dashboard["gpu-tenant"]
}
moved {
  from = kubectl_manifest.dashboard_node_exporter[0]
  to   = kubectl_manifest.grafana_dashboard["node-exporter-full"]
}
moved {
  from = kubectl_manifest.dashboard_dcgm_exporter[0]
  to   = kubectl_manifest.grafana_dashboard["dcgm-exporter"]
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
# tolerations, so on this cluster's tainted GPU nodes it cannot land and
# AcceleratedHardwareReady stays stuck False — a detection gap exactly on the
# nodes that matter. The add-on exposes dcgmAgent.tolerations in its
# configurationValues schema (v1.3.0+), so we grant the accelerator taints there
# (local.dcgm_server_tolerations — kept in sync with the GPU node taint ledger,
# including the Capacity Block `capacity-reservation` taint). Scoped (not a
# blanket Exists) so it never leaks onto unrelated tainted nodes. This looks like
# an upstream default oversight (the agent itself tolerates all taints,
# dcgm-server does not); if AWS fixes the default, this block can be dropped.
resource "aws_eks_addon" "node_monitoring_agent" {
  count = var.enable_node_monitoring_agent ? 1 : 0

  cluster_name  = module.eks.cluster_name
  addon_name    = "eks-node-monitoring-agent"
  addon_version = var.node_monitoring_agent_version # null => EKS default for the K8s version

  configuration_values = jsonencode({
    dcgmAgent = {
      tolerations = local.dcgm_server_tolerations
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
            # status="true" == 0 means the Ready series is present but not true, i.e. the
            # NMA actively reported the condition False (or, rarely, Unknown). It does NOT
            # catch an NMA that has STOPPED reporting: a stale NodeCondition keeps its last
            # value (Kubernetes has no controller that flips a non-Ready condition to Unknown
            # when its reporter dies), so the series simply freezes at its last-seen value.
            # That blind spot is covered by NodeMonitoringAgentDown below, which watches the
            # DaemonSets directly. The message says "not True" so on-call is not misled into
            # hunting for an explicit False when the value could be Unknown.
            expr  = "kube_node_status_condition{condition=~\"KernelReady|ContainerRuntimeReady|NetworkingReady|StorageReady\",status=\"true\"} == 0"
            "for" = "5m"
            labels = {
              severity  = "warning"
              component = "node-monitoring-agent"
            }
            annotations = {
              summary     = "{{ $labels.condition }} is not True on {{ $labels.node }}"
              description = "The Node Monitoring Agent reports {{ $labels.condition }} not True (False or Unknown) for 5m."
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

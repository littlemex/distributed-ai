# accelerator-stuck-node-reaper.tf
# Steady-state recovery for a NodeClaim already stuck deleting because its node went
# NotReady and the kubelet can no longer drain it.
#
# This is deliberately SEPARATE from karpenter.tf's destroy-time wait gate:
#   - destroy-time: blocks teardown until Karpenter clears NodeClaims itself, never touching
#     a live NodeClaim finalizer.
#   - steady-state (here): opt-in per pool, targets ONLY a NodeClaim that is already deleting
#     and whose node has stayed NotReady beyond a threshold, then terminates EC2 first and
#     clears the finalizer only after the instance is gone.
#
# NodeRepair stays disabled (observability.tf) on purpose. This reaper is narrower and auditable:
# it does not auto-replace every unhealthy node, and it refuses to act while the node is still
# Ready or while the backing EC2 instance still exists and has not been confirmed terminated.

locals {
  accelerator_stuck_node_reaper_name = "accelerator-stuck-node-reaper"
  # IAM role names cap at 64 chars; keep the stable suffix intact and trim only cluster_name.
  accelerator_stuck_node_reaper_role_cluster_name_max = 64 - length(local.accelerator_stuck_node_reaper_name) - 1
  accelerator_stuck_node_reaper_role_name             = "${substr(var.cluster_name, 0, local.accelerator_stuck_node_reaper_role_cluster_name_max)}-${local.accelerator_stuck_node_reaper_name}"

  accelerator_stuck_node_reaper_pools = {
    for k, p in var.accelerator_pools : k => {
      notready_threshold = p.stuck_node_reaper_notready_threshold
    } if p.stuck_node_reaper_enabled
  }

  accelerator_stuck_node_reaper_enabled = length(local.accelerator_stuck_node_reaper_pools) > 0

  # dry_run is cluster-wide (one CronJob): arm it only when EVERY enabled pool has explicitly set
  # stuck_node_reaper_dry_run=false. Any enabled pool still in dry-run keeps the whole reaper in
  # observe-only mode — the safe direction.
  accelerator_stuck_node_reaper_dry_run = anytrue([
    for k, p in var.accelerator_pools : p.stuck_node_reaper_dry_run if p.stuck_node_reaper_enabled
  ])

  # A dead kubelet can leave EC2 in shutting-down for minutes; a 15-minute wait with 15-second
  # polls bounds one recovery attempt without hammering the EC2 API.
  accelerator_stuck_node_reaper_config = {
    region                          = var.region
    karpenter_termination_finalizer = "karpenter.sh/termination"
    termination_wait_seconds        = 900
    poll_interval_seconds           = 15
    dry_run                         = local.accelerator_stuck_node_reaper_dry_run
    pools                           = local.accelerator_stuck_node_reaper_pools
  }

  # Bound a single run even if several stuck NodeClaims queue up; later CronJob ticks can resume.
  accelerator_stuck_node_reaper_active_deadline_seconds = local.accelerator_stuck_node_reaper_config.termination_wait_seconds * 2
}

data "aws_iam_policy_document" "accelerator_stuck_node_reaper_assume" {
  count = local.accelerator_stuck_node_reaper_enabled ? 1 : 0

  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "accelerator_stuck_node_reaper" {
  count = local.accelerator_stuck_node_reaper_enabled ? 1 : 0

  name               = local.accelerator_stuck_node_reaper_role_name
  assume_role_policy = data.aws_iam_policy_document.accelerator_stuck_node_reaper_assume[0].json
  tags               = var.tags
}

data "aws_iam_policy_document" "accelerator_stuck_node_reaper" {
  count = local.accelerator_stuck_node_reaper_enabled ? 1 : 0

  statement {
    sid = "DescribeInstances"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceStatus",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "TerminateEnabledPoolInstances"
    actions   = ["ec2:TerminateInstances"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/kubernetes.io/cluster/${module.eks.cluster_name}"
      values   = ["owned"]
    }

    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/karpenter.sh/nodepool"
      values   = sort(keys(local.accelerator_stuck_node_reaper_pools))
    }
  }
}

resource "aws_iam_role_policy" "accelerator_stuck_node_reaper" {
  count = local.accelerator_stuck_node_reaper_enabled ? 1 : 0

  name   = "ec2-recover-stuck-nodeclaims"
  role   = aws_iam_role.accelerator_stuck_node_reaper[0].id
  policy = data.aws_iam_policy_document.accelerator_stuck_node_reaper[0].json
}

resource "kubectl_manifest" "accelerator_stuck_node_reaper_sa" {
  count = local.accelerator_stuck_node_reaper_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ServiceAccount"
    metadata = {
      name      = local.accelerator_stuck_node_reaper_name
      namespace = local.karpenter_namespace
    }
  })

  depends_on = [helm_release.karpenter]
}

resource "aws_eks_pod_identity_association" "accelerator_stuck_node_reaper" {
  count = local.accelerator_stuck_node_reaper_enabled ? 1 : 0

  cluster_name    = module.eks.cluster_name
  namespace       = local.karpenter_namespace
  service_account = local.accelerator_stuck_node_reaper_name
  role_arn        = aws_iam_role.accelerator_stuck_node_reaper[0].arn
  tags            = var.tags

  depends_on = [kubectl_manifest.accelerator_stuck_node_reaper_sa]
}

resource "kubectl_manifest" "accelerator_stuck_node_reaper_clusterrole" {
  count = local.accelerator_stuck_node_reaper_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRole"
    metadata   = { name = local.accelerator_stuck_node_reaper_name }
    rules = [
      {
        apiGroups = [""]
        resources = ["nodes"]
        verbs     = ["get", "delete"]
      },
      {
        apiGroups = ["karpenter.sh"]
        resources = ["nodeclaims"]
        verbs     = ["get", "list", "patch"]
      },
    ]
  })

  depends_on = [helm_release.karpenter]
}

resource "kubectl_manifest" "accelerator_stuck_node_reaper_clusterrolebinding" {
  count = local.accelerator_stuck_node_reaper_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRoleBinding"
    metadata   = { name = local.accelerator_stuck_node_reaper_name }
    roleRef = {
      apiGroup = "rbac.authorization.k8s.io"
      kind     = "ClusterRole"
      name     = local.accelerator_stuck_node_reaper_name
    }
    subjects = [{
      kind      = "ServiceAccount"
      name      = local.accelerator_stuck_node_reaper_name
      namespace = local.karpenter_namespace
    }]
  })

  depends_on = [
    kubectl_manifest.accelerator_stuck_node_reaper_sa,
    kubectl_manifest.accelerator_stuck_node_reaper_clusterrole,
  ]
}

resource "kubectl_manifest" "accelerator_stuck_node_reaper_configmap" {
  count = local.accelerator_stuck_node_reaper_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata = {
      name      = local.accelerator_stuck_node_reaper_name
      namespace = local.karpenter_namespace
    }
    data = {
      "config.json" = jsonencode(local.accelerator_stuck_node_reaper_config)
      "reaper.py"   = file("${path.module}/scripts/accelerator_stuck_node_reaper.py")
    }
  })

  depends_on = [helm_release.karpenter]
}

resource "kubectl_manifest" "accelerator_stuck_node_reaper_cronjob" {
  count = local.accelerator_stuck_node_reaper_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "batch/v1"
    kind       = "CronJob"
    metadata = {
      name      = local.accelerator_stuck_node_reaper_name
      namespace = local.karpenter_namespace
    }
    spec = {
      schedule          = "*/5 * * * *"
      concurrencyPolicy = "Forbid"
      # Keep failed Job logs/history for postmortems; history limits prune them without a TTL.
      successfulJobsHistoryLimit = 1
      failedJobsHistoryLimit     = 3
      jobTemplate = {
        spec = {
          activeDeadlineSeconds = local.accelerator_stuck_node_reaper_active_deadline_seconds
          backoffLimit          = 0
          template = {
            metadata = {
              labels = { "app.kubernetes.io/name" = local.accelerator_stuck_node_reaper_name }
            }
            spec = {
              serviceAccountName = local.accelerator_stuck_node_reaper_name
              restartPolicy      = "Never"
              securityContext = {
                runAsNonRoot = true
                runAsUser    = 65532
                seccompProfile = {
                  type = "RuntimeDefault"
                }
              }
              # Run on the stable system tier so the reaper never lands on a node it might reap.
              nodeSelector = {
                "karpenter.sh/controller" = "true"
              }
              # Match the optional sanctuary taint on the system tier if it is enabled later.
              tolerations = [{
                key      = "CriticalAddonsOnly"
                operator = "Exists"
                effect   = "NoSchedule"
              }]
              containers = [{
                name = "reaper"
                # Pinned by digest: this controller can terminate EC2 instances, so a moving tag would
                # weaken reproducibility and supply-chain integrity. Update the digest deliberately
                # when bumping the runtime (matches the digest-pinning convention used by the
                # image-build/prewarm templates in this chart).
                image           = "public.ecr.aws/docker/library/python:3.12-slim@sha256:229a2c5bfa27522db7815ea81f9bed70af17ccb9de9fc7ad142b1877b5830d36"
                imagePullPolicy = "IfNotPresent"
                command         = ["python", "/opt/reaper/reaper.py", "/opt/reaper/config.json"]
                env = [
                  { name = "PYTHONDONTWRITEBYTECODE", value = "1" },
                  { name = "PYTHONUNBUFFERED", value = "1" },
                ]
                resources = {
                  requests = {
                    cpu    = "50m"
                    memory = "128Mi"
                  }
                  limits = {
                    cpu    = "200m"
                    memory = "256Mi"
                  }
                }
                securityContext = {
                  allowPrivilegeEscalation = false
                  readOnlyRootFilesystem   = true
                  capabilities             = { drop = ["ALL"] }
                }
                volumeMounts = [
                  {
                    name      = "reaper"
                    mountPath = "/opt/reaper"
                    readOnly  = true
                  },
                  {
                    name      = "tmp"
                    mountPath = "/tmp"
                  },
                ]
              }]
              volumes = [
                {
                  name = "reaper"
                  configMap = {
                    name = local.accelerator_stuck_node_reaper_name
                  }
                },
                {
                  name     = "tmp"
                  emptyDir = {}
                },
              ]
            }
          }
        }
      }
    }
  })

  depends_on = [
    aws_iam_role_policy.accelerator_stuck_node_reaper,
    aws_eks_pod_identity_association.accelerator_stuck_node_reaper,
    kubectl_manifest.accelerator_stuck_node_reaper_clusterrolebinding,
    kubectl_manifest.accelerator_stuck_node_reaper_configmap,
  ]
}

# kueue.tf
# Kueue — a job-level queueing/admission layer (kubernetes-sigs/kueue). It does not replace
# kube-scheduler and does not provision nodes; it decides WHEN a Job/TrainJob/RayJob is allowed
# to create its Pods. Node provisioning for the Pods it admits is still Karpenter's job, exactly
# as it is today for any Pod this cluster creates.
#
# This file installs the Kueue CONTROLLER only, always on (kueue_enabled defaults to true, like
# trainer_enabled). It deliberately does NOT create any ClusterQueue/ResourceFlavor/LocalQueue —
# those are workload-shape-specific (which NodePool, how many GPUs, which namespace), the same
# reason accelerator_pools lives in a *.auto.tfvars file and not inline here. A reference example
# lives in manifests/kueue-reference/ (applied with `kubectl apply`, not by `terraform apply`);
# see its README for the queue-name label and the opt-in label a namespace needs.
#
# Verified facts (chart @ var.kueue_chart_version, read from kubernetes-sigs/kueue main 2026-10-21):
#   - Chart oci://registry.k8s.io/kueue/charts/kueue. CRDs ship under templates/crd/, not in a
#     crds/ directory — unlike Karpenter (karpenter.tf), there is no separate "kueue-crd" chart,
#     and `helm uninstall` DOES remove the CRDs. Deleting this release deletes every
#     ClusterQueue/LocalQueue/ResourceFlavor/Workload object with it; delete Workloads/jobs first.
#   - integrations.frameworks defaults already include "trainer.kubeflow.org/trainjob" and
#     "ray.io/rayjob" / "ray.io/raycluster" / "ray.io/rayservice" — the two job kinds this repo's
#     charts/experiments already uses need no extra integration config, only the queue-name label
#     on the workload (see manifests/kueue-reference/).
#   - The mutating/validating webhooks for batch/v1 Job, JobSet, TrainJob, RayJob, etc. default to
#     namespaceSelector "NotIn [kube-system, <release namespace>]" — i.e. EVERY OTHER NAMESPACE IN
#     THE CLUSTER, with failurePolicy: Fail on most of them. On a cluster with workloads this repo
#     does not own, that is a real blast radius: if the webhook pod is ever unreachable, Job/JobSet
#     creation fails cluster-wide, not just for queue-opted-in workloads. managerConfig below pins
#     the documented opt-in pattern instead (Kueue's own "Opt-in Namespace Management" task doc),
#     so only namespaces carrying the `managed-by-kueue=true` label are ever in scope. Label a
#     namespace with `kubectl label namespace <ns> managed-by-kueue=true` before using a queue
#     there; everything else on the cluster is untouched by Kueue's webhooks.
#   - waitForPodsReady is OFF by default. For a multi-pod job (TrainJob's JobSet, RayCluster), that
#     is a real gang-admission gap: Kueue admits at the Workload (whole-job) level, but two
#     same-size jobs that each fit only half in the free capacity can deadlock if issue (b) leaves
#     Pod placement up to the default scheduler with nothing to resolve a half-and-half split.
#     Enabled below with blockAdmission=true, which sequences admission so a second job never starts
#     landing pods until the first job's pods are confirmed Ready — at the cost of no two jobs
#     *starting* their pod creation concurrently even if there would have been room for both.

variable "kueue_enabled" {
  description = <<-EOT
    Install Kueue (kubernetes-sigs/kueue), the job-queueing/admission controller. Default on: an
    unlabelled namespace is completely unaffected by it (see managedJobsNamespaceSelector below),
    so leaving this on does not change behavior for workloads that never opt a namespace in.
    Disable only to remove the controller and its CRDs entirely (see kueue.tf's CRD-uninstall note).
  EOT
  type        = bool
  default     = true
}

variable "kueue_chart_version" {
  description = "Helm chart version for Kueue (oci://registry.k8s.io/kueue/charts/kueue)."
  type        = string
  default     = "0.20.2"
}

resource "helm_release" "kueue" {
  count = var.kueue_enabled ? 1 : 0

  name             = "kueue"
  repository       = "oci://registry.k8s.io/kueue/charts"
  chart            = "kueue"
  version          = var.kueue_chart_version
  namespace        = "kueue-system"
  create_namespace = true

  wait    = true
  atomic  = true
  timeout = 300

  values = [yamlencode({
    managerConfig = {
      # Opt-in only (Kueue's own documented pattern, not a local invention): a namespace is in
      # scope for Kueue's webhooks only once labelled managed-by-kueue=true. See this file's
      # header comment for why the chart's own default (every namespace except kube-system) is
      # the wrong default on a cluster shared with workloads this repo does not own.
      managedJobsNamespaceSelector = {
        matchLabels = {
          "managed-by-kueue" = "true"
        }
      }
      waitForPodsReady = {
        enable         = true
        blockAdmission = true
      }
    }
  })]

  depends_on = [module.eks]
}

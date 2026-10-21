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
# Verified facts (pulled and read directly, not from memory: `helm pull
# oci://registry.k8s.io/kueue/charts/kueue --version 0.20.2 --untar`, 2026-10-22):
#   - Chart oci://registry.k8s.io/kueue/charts/kueue. CRDs ship under templates/crd/, not in a
#     crds/ directory — unlike Karpenter (karpenter.tf), there is no separate "kueue-crd" chart,
#     and `helm uninstall` DOES remove the CRDs. Deleting this release deletes every
#     ClusterQueue/LocalQueue/ResourceFlavor/Workload object with it; delete Workloads/jobs first.
#   - At 0.20.2, `values.yaml`'s `managerConfig` is ONE string field,
#     `managerConfig.controllerManagerConfigYaml`, rendered with a single `fromYaml` and no partial
#     merge, by the kueue chart's own manager-config ConfigMap template and its webhook manifest
#     template (not paths in this repository). A
#     `structuredOverrides` sub-key that merges onto the chart's own defaults exists on this
#     project's `main` branch (`_helpers.tpl`'s `kueue.managerConfig`/`kueue.mergeManagerConfig`)
#     but is NOT in 0.20.2 — setting it there is silently read by nothing (a first version of this
#     file did exactly that, verified live by rendering both ways and diffing the
#     MutatingWebhookConfiguration's `namespaceSelector`: identical, unchanged from the chart's own
#     default, in both). So `local.kueue_manager_config_yaml` below is the WHOLE document, copied
#     from this chart version's own default value plus two additions, not a partial override.
#   - integrations.frameworks defaults already include "trainer.kubeflow.org/trainjob" and
#     "ray.io/rayjob" / "ray.io/raycluster" / "ray.io/rayservice" — the two job kinds this repo's
#     charts/experiments already uses need no extra integration config, only the queue-name label
#     on the workload (see manifests/kueue-reference/). Carried through unchanged below.
#   - The mutating/validating webhooks for batch/v1 Job, JobSet, TrainJob, RayJob, etc. read their
#     `namespaceSelector` from this same document's `managedJobsNamespaceSelector`, and default (if
#     that key is absent, as the chart ships it) to "NotIn [kube-system, <release namespace>]" —
#     i.e. EVERY OTHER NAMESPACE IN THE CLUSTER, with failurePolicy: Fail on most of them. On a
#     cluster with workloads this repo does not own, that is a real blast radius: if the webhook
#     pod is ever unreachable, Job/JobSet creation fails cluster-wide, not just for queue-opted-in
#     workloads. The document below sets `managedJobsNamespaceSelector` to Kueue's own documented
#     opt-in pattern instead ("Opt-in Namespace Management" task doc), so only namespaces carrying
#     the `managed-by-kueue=true` label are ever in scope. Label a namespace with
#     `kubectl label namespace <ns> managed-by-kueue=true` before using a queue there; everything
#     else on the cluster is untouched by Kueue's webhooks. Confirmed by rendering with this file's
#     actual values and grepping `mjob.kb.io`'s `namespaceSelector` out of the rendered
#     MutatingWebhookConfiguration (see this change's PR for the rendered diff).
#   - waitForPodsReady is OFF by default. For a multi-pod job (TrainJob's JobSet, RayCluster), that
#     is a real gang-admission gap: Kueue admits at the Workload (whole-job) level but does not
#     itself place Pods, so two same-size jobs that each fit only half in the free capacity can
#     deadlock, each holding half the capacity the other needs and neither ever reaching Ready.
#     Enabled below with blockAdmission=true, which sequences admission so a second job never starts
#     landing pods until the first job's pods are confirmed Ready — at the cost of no two jobs
#     *starting* their pod creation concurrently even if there would have been room for both, and of
#     evicting (not just failing to admit) a Workload whose Pods are not all Ready within `timeout`.
#     Left at the chart's own 30m default here: the one live measurement this change has (a fresh
#     g6.2xlarge spot NodeClaim to its Pod Running on distai-eks, ap-northeast-1, 2026-10-22) took
#     about 2.5 minutes, but that is one data point on one instance type in one AZ, not a basis for
#     tightening a 30m default — a NodePool whose instance types need a real capacity search, or an
#     image this registry has not cached, will take longer. Measure this cluster's own NodePools
#     before shortening it.

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

# The whole controller_manager_config.yaml document for chart 0.20.2, which has no partial-override
# mechanism (see this file's header comment): copied from this chart version's own
# values.yaml["managerConfig"]["controllerManagerConfigYaml"] verbatim, with exactly two additions
# (managedJobsNamespaceSelector, waitForPodsReady) and nothing removed or reordered, so a future
# `terraform plan` diff against a bumped kueue_chart_version shows only what that version's own
# default actually changed, not noise from this file having restated it differently.
locals {
  kueue_manager_config_yaml = <<-EOT
    apiVersion: config.kueue.x-k8s.io/v1beta2
    kind: Configuration
    health:
      healthProbeBindAddress: :8081
    metrics:
      bindAddress: :8443
    webhook:
      port: 9443
    leaderElection:
      leaderElect: true
      resourceName: c1f6bfd2.kueue.x-k8s.io
    controller:
      groupKindConcurrency:
        Job.batch: 5
        Pod: 5
        Workload.kueue.x-k8s.io: 10
        LocalQueue.kueue.x-k8s.io: 5
        Cohort.kueue.x-k8s.io: 1
        ClusterQueue.kueue.x-k8s.io: 5
        ResourceFlavor.kueue.x-k8s.io: 1
    clientConnection:
      qps: 300
      burst: 500
    waitForPodsReady:
      timeout: 30m
      blockAdmission: true
    # Opt-in only (Kueue's own documented pattern -- "Opt-in Namespace Management" in its task
    # docs -- not a local invention): a namespace is in scope for Kueue's webhooks only once
    # labelled managed-by-kueue=true. See this file's header comment for why the chart's own
    # default (every namespace except kube-system) is the wrong default on a cluster shared with
    # workloads this repo does not own.
    managedJobsNamespaceSelector:
      matchLabels:
        managed-by-kueue: "true"
    integrations:
      frameworks:
      - "batch/job"
      - "kubeflow.org/mpijob"
      - "ray.io/rayjob"
      - "ray.io/rayservice"
      - "ray.io/raycluster"
      - "jobset.x-k8s.io/jobset"
      - "workload.codeflare.dev/appwrapper"
      - "trainer.kubeflow.org/trainjob"
      - "pod"
      - "deployment"
      - "statefulset"
      - "leaderworkerset.x-k8s.io/leaderworkerset"
  EOT
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
      controllerManagerConfigYaml = local.kueue_manager_config_yaml
    }
  })]

  depends_on = [module.eks]
}

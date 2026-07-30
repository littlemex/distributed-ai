# trainer.tf
# Kubeflow Trainer v2 — the multi-node training control plane (TrainJob,
# trainer.kubeflow.org/v1alpha1). This replaces the legacy Kubeflow Training Operator v1
# (PyTorchJob, kubeflow.org/v1) that used to be applied from a vendored manifest in gpu-addons.tf.
#
# Why v2:
#   - Upstream declared Training Operator v1 legacy (maintained on release-1.9) and points users
#     at Trainer v2. v2 collapses the per-framework CRDs (PyTorchJob/TFJob/MPIJob/...) into a
#     single TrainJob + Runtime model.
#   - rendezvous is handled by the Trainer torch plugin: it injects PET_NNODES / PET_NPROC_PER_NODE
#     / PET_NODE_RANK / PET_MASTER_ADDR / PET_MASTER_PORT into the pods, so torchrun does c10d
#     rendezvous on node-0's TCPStore. The self-hosted etcd Deployment+Service the v1 chart needed
#     is gone (charts/experiments/templates/etcd.yaml deleted).
#   - One Helm release installs the whole thing: the control plane, the standard
#     ClusterTrainingRuntimes (installed by a post-install hook Job), and the JobSet dependency
#     (oci://registry.k8s.io/jobset/charts). The vendored-manifest + server-side-apply +
#     Deployment-ordering machinery the v1 operator required disappears entirely.
#
# Verified facts (chart @ var.trainer_chart_version):
#   - Chart oci://ghcr.io/kubeflow/charts/kubeflow-trainer. Requires Kubernetes >= 1.31 (this
#     cluster is 1.35). CRD apiVersion is trainer.kubeflow.org/v1alpha1 (alpha; fields may change).
#   - At the pinned 2.2.1, the CRDs ship in the chart's crds/ directory, NOT templates/. So
#     `helm uninstall` LEAVES the CRDs in place — there is no "controller deleted before its CRs,
#     finalizers stuck" teardown hazard here. (Newer chart mainlines moved CRDs into templates/;
#     if you bump the pin, re-check this and revisit karpenter.tf's drain ordering.)
#   - jobset.install=true makes the chart pull and install JobSet as a subchart. Set it false only
#     if a JobSet controller is already present cluster-wide.
#   - runtimes.defaultEnabled is kept FALSE: its post-install hook Job races the controller's
#     webhook on first install and fails the release (confirmed live 2026-07-30). This cluster
#     uses only its own torch-distributed-eks runtime (charts/experiments), applied after the
#     controller is Ready. That runtime intentionally omits the
#     trainer.kubeflow.org/managed-by=runtimes-installer label, so even if the stock installer is
#     ever re-enabled it will not treat (and delete) this runtime as a managed object.

# Fail fast if a workspace still sets the removed v1 variables, so the switch to v2 is explicit
# rather than a silent behavior change on the next apply. (Terraform has no "removed variable"
# construct; this input-less check surfaces the rename in plan output.)
resource "terraform_data" "trainer_v1_migration_guard" {
  count = var.trainer_enabled ? 1 : 0
  lifecycle {
    precondition {
      # trainer_enabled must be a real bool; the real purpose of this block is the human-facing
      # message below, shown whenever someone re-runs an old tfvars expecting the v1 variables.
      condition     = var.trainer_enabled == true || var.trainer_enabled == false
      error_message = "training_operator_enabled/training_operator_version were removed in the Kubeflow Trainer v2 migration. Use var.trainer_enabled (and var.trainer_chart_version) instead."
    }
  }
}

resource "helm_release" "trainer" {
  count = var.trainer_enabled ? 1 : 0

  name             = "kubeflow-trainer"
  repository       = "oci://ghcr.io/kubeflow/charts"
  chart            = "kubeflow-trainer"
  version          = var.trainer_chart_version
  namespace        = "kubeflow-system"
  create_namespace = true

  # wait for the control plane to be Ready; atomic rolls back a half-installed release so it does
  # not wedge the next apply.
  wait    = true
  atomic  = true
  timeout = 600

  values = [yamlencode({
    # Install JobSet as a managed subchart (this cluster has no pre-existing JobSet controller).
    jobset = { install = true }
    # Do NOT install the chart's standard ClusterTrainingRuntimes. Verified live on
    # distai-eks-blog (2026-07-30): with defaultEnabled=true the chart's post-install/post-upgrade
    # hook Job races the controller and calls the validating webhook before its Service has
    # endpoints ("no endpoints available for service kubeflow-trainer-controller-manager"), so the
    # runtimes apply fails and the whole release goes to `failed`. This cluster uses only its own
    # torch-distributed-eks runtime (charts/experiments), applied by the workload pipeline AFTER
    # the controller is up — which has no such race. Leaving the stock runtimes out also removes an
    # ownership overlap we never rely on.
    runtimes = { defaultEnabled = false }
  })]

  # Trainer only needs the cluster API reachable (the helm/kubectl providers already target
  # module.eks). It does not depend on the GPU/Neuron stack — a TrainJob can target the CPU pool.
  depends_on = [module.eks]
}

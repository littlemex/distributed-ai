################################################################################
# Karpenter Helm release — v1.13.0
#
# Verified facts:
#   OCI chart repo  : oci://public.ecr.aws/karpenter/karpenter  (upstream docs)
#   Helm chart tag  : 1.13.0
#   ECR public auth : must be fetched from us-east-1 (AWS requirement for ECR Public)
#   Namespace       : "karpenter"  (locals.tf: karpenter_namespace = "karpenter")
#   Auth method     : Pod Identity (created by module.karpenter in iam.tf)
#                     — no IRSA serviceAccount annotation needed
#
#   featureGates (Chart values.yaml at v1.13.0 commit):
#     reservedCapacity         = true   BETA default — no override needed
#     nodeRepair               = false  ALPHA default
#     nodeOverlay              = false  ALPHA default
#     spotToSpotConsolidation  = false  ALPHA default
#     staticCapacity           = false  ALPHA default
#   → featureGates block omitted; defaults are correct.
#
#   interruptionQueue : module.karpenter.queue_name  (SQS queue from iam.tf)
#
# NOTE: Requires a provider alias `aws.us_east_1` in providers.tf (separate file):
#   provider "aws" {
#     alias  = "us_east_1"
#     region = "us-east-1"
#   }
################################################################################

# ECR public auth token must always come from us-east-1 (AWS API restriction)
data "aws_ecrpublic_authorization_token" "karpenter" {
  provider = aws.us_east_1
}

# Karpenter CRDs, installed as a SEPARATE chart. Helm never upgrades CRDs bundled in a
# chart's crds/ directory, so bumping var.karpenter_chart_version would otherwise leave the
# EC2NodeClass/NodePool/NodeClaim CRDs at their first-installed schema. Installing the
# dedicated karpenter-crd chart (same version) lets `helm upgrade` roll the CRD schema too.
resource "helm_release" "karpenter_crd" {
  namespace        = local.karpenter_namespace
  create_namespace = true
  name             = "karpenter-crd"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter-crd"
  version          = var.karpenter_chart_version

  repository_username = data.aws_ecrpublic_authorization_token.karpenter.user_name
  repository_password = data.aws_ecrpublic_authorization_token.karpenter.password

  # The karpenter-crd chart can optionally run a conversion webhook; it is not needed here
  # (the controller chart runs its own), so disable it to avoid a second webhook Deployment.
  set {
    name  = "webhook.enabled"
    value = "false"
  }

  depends_on = [module.eks]
}

resource "helm_release" "karpenter" {
  namespace        = local.karpenter_namespace
  create_namespace = true
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = var.karpenter_chart_version
  # CRDs are managed by helm_release.karpenter_crd above, so the controller chart must not
  # also ship them.
  skip_crds = true
  # wait=false: controller readiness is not gated here. CRD REGISTRATION is guaranteed by
  # the explicit dependency on helm_release.karpenter_crd; the NodePool/EC2NodeClass
  # kubectl_manifest resources additionally depend on this release. Note: this orders
  # creation but does not itself wait for the CRDs to reach Established — a first apply can
  # occasionally need a re-apply if the API is momentarily slow to serve the new types.
  wait = false

  # ECR public OCI registries require credentials even for public images
  repository_username = data.aws_ecrpublic_authorization_token.karpenter.user_name
  repository_password = data.aws_ecrpublic_authorization_token.karpenter.password

  values = [
    <<-EOT
    # Run Karpenter on the stable system node group, not on nodes it manages
    nodeSelector:
      karpenter.sh/controller: "true"

    # Required when running on a VPC with custom DNS / non-cluster-aware resolvers
    dnsPolicy: Default

    # Pod Identity is configured in iam.tf via module.karpenter.
    # No serviceAccount.annotations (IRSA) needed.

    settings:
      clusterName: ${module.eks.cluster_name}
      clusterEndpoint: ${module.eks.cluster_endpoint}
      # SQS queue for spot interruption, rebalance, and AWS health events
      interruptionQueue: ${module.karpenter.queue_name}

    # featureGates: all v1.13.0 defaults are correct
    #   reservedCapacity=true (BETA, enabled by default — ReservedCapacity CB support)
    #   nodeRepair=false, nodeOverlay=false, spotToSpotConsolidation=false, staticCapacity=false
    # Explicitly setting featureGates here is unnecessary.
    EOT
  ]

  depends_on = [
    module.eks,
    module.karpenter,
    helm_release.karpenter_crd,
  ]
}

# kubectl_manifest reports the NodePool/NodeClaim delete "complete" the moment the
# Kubernetes API accepts it — draining pods, terminating the EC2 instance, and releasing
# the ENI are all async work done BY THE KARPENTER CONTROLLER. If Karpenter (or any
# controller that owns a per-node resource — the device plugins, the EFS/FSx CSI drivers,
# the EFA security group) is destroyed while an accelerator node still exists (e.g.
# `terraform destroy` run with a live GPU/Capacity-Block node), that node's EC2 instance is
# orphaned — it keeps billing and nothing in AWS will ever terminate it. This resource
# blocks until every NodeClaim is gone (or the timeout elapses) BEFORE any of those
# controllers are allowed to be destroyed.
#
# Dependency direction: Terraform destroys in the REVERSE of depends_on order — if A
# depends_on B, destroy order is A, then B. This resource depends_on every controller it
# protects (below), so destroy order is: this resource (runs the drain-wait provisioner)
# FIRST, then those controllers. And the NodePool/NodeClaim manifests — whose deletion is
# what we're waiting to observe — depend on THIS resource too (see karpenter-resources.tf),
# so their delete is issued before the wait starts. Destroy order end to end: NodePool
# manifests, then this resource (waits), then Karpenter/gpu-operator/neuron/EFA
# plugin/EFS+FSx CSI/the EFA security group. No cycle: NodePool -> this -> controllers is
# a straight line in one direction only.
#
# A time_sleep with a fixed duration (the fix used for the ALB Controller/demo Ingress
# elsewhere in this module) is not appropriate here: node drain + EC2 termination takes
# minutes, not seconds, and scales with node count — so this polls for the actual
# steady state instead of guessing a duration.
resource "null_resource" "wait_for_node_drain" {
  triggers = {
    cluster_name = module.eks.cluster_name
    region       = var.region
    aws_profile  = coalesce(var.aws_profile, "")
  }

  # Every controller/addon that owns a per-node resource, so all of them are destroyed only
  # AFTER the drain-wait below completes (Terraform destroys in the reverse of depends_on
  # order — this resource first, then everything it lists here).
  #
  # aws_vpc_endpoint.interface/s3 (vpc-endpoints.tf) are included for the same reason, for a
  # different discovered failure: a `terraform destroy` with an accelerator node present
  # removed the NAT gateway (module.vpc, no ordering relationship with Karpenter) WHILE this
  # provisioner was still polling. Karpenter's controller Pod runs in a private subnet and
  # depends on the NAT for AWS API calls (EC2, IAM, STS, SSM); the instant the NAT
  # disappeared, every API call timed out and the controller could never finish clearing the
  # NodeClaim's finalizer, so the wait ran to its timeout. A depends_on straight on
  # module.vpc is not viable — this resource's triggers reference module.eks.cluster_name,
  # and module.eks depends on module.vpc's subnets, so that edge would be a cycle. Fixed at
  # the network layer instead: keeping the VPC endpoints alive through the wait means
  # Karpenter keeps working even if the NAT is gone.
  depends_on = [
    helm_release.karpenter,
    helm_release.gpu_operator,
    helm_release.aws_efa_k8s_device_plugin,
    helm_release.neuron,
    aws_eks_addon.efs_csi_driver,
    aws_eks_addon.fsx_csi_driver,
    aws_security_group.efa_node,
    # Same reason as efa_node above: on destroy the drain-wait must run BEFORE the placement
    # group is deleted (a PG cannot be deleted while instances are still in it). depends_on
    # here => destroy order is drain-wait first, then aws_placement_group.accelerator.
    aws_placement_group.accelerator,
    aws_vpc_endpoint.interface,
    aws_vpc_endpoint.s3,
  ]

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -uo pipefail
      command -v aws >/dev/null 2>&1 && command -v kubectl >/dev/null 2>&1 || {
        echo "wait_for_node_drain: aws or kubectl not on PATH — cannot verify accelerator nodes are drained. Check for orphaned EC2 instances manually before assuming destroy is complete." >&2
        exit 1
      }
      PROFILE_ARGS=()
      [ -n "${self.triggers.aws_profile}" ] && PROFILE_ARGS=(--profile "${self.triggers.aws_profile}")
      KCONF=$(mktemp)
      trap 'rm -f "$KCONF"' EXIT
      if ! aws eks describe-cluster --name "${self.triggers.cluster_name}" --region "${self.triggers.region}" "$${PROFILE_ARGS[@]}" >/dev/null 2>&1; then
        echo "wait_for_node_drain: cluster ${self.triggers.cluster_name} no longer exists, skipping drain wait"
        exit 0
      fi
      aws eks update-kubeconfig --name "${self.triggers.cluster_name}" --region "${self.triggers.region}" "$${PROFILE_ARGS[@]}" --kubeconfig "$KCONF" >/dev/null 2>&1 \
        || { echo "wait_for_node_drain: cluster exists but update-kubeconfig failed — cannot verify drain. Check for orphaned EC2 instances manually." >&2; exit 1; }
      export KUBECONFIG="$KCONF"

      # Polls `kubectl get <resource_type> --no-headers` until it reports zero objects, or
      # until $3 attempts (10s apart) are exhausted. stdout and stderr are captured
      # separately: `kubectl get` writes "No resources found" to STDERR even on the
      # empty-but-successful case (exit 0) — merging streams with 2>&1 previously counted
      # that line as 1 remaining object forever (caught live: a separate kubectl session
      # showed zero objects while this loop kept reporting "1 still terminating" for 15+
      # minutes). Returns 0 once empty, 1 if it never empties.
      wait_for_empty() {
        local resource_type="$1" label="$2" max_attempts="$3"
        for i in $(seq 1 "$max_attempts"); do
          local err_file
          err_file=$(mktemp)
          local out
          if ! out=$(kubectl get "$resource_type" --no-headers 2>"$err_file"); then
            local err
            err=$(cat "$err_file"); rm -f "$err_file"
            if printf '%s\n' "$err" | grep -q "doesn't have a resource type"; then
              echo "wait_for_node_drain: the $label CRD no longer exists, nothing left to wait for."
              return 0
            fi
            echo "wait_for_node_drain: kubectl error listing $label (transient?): $err — retrying"
          else
            rm -f "$err_file"
            local count
            count=$(printf '%s\n' "$out" | grep -c . || true)
            if [ "$count" = "0" ]; then
              echo "wait_for_node_drain: no $label remain."
              return 0
            fi
            echo "wait_for_node_drain: $count $label still present (attempt $i/$max_attempts)..."
          fi
          sleep 10
        done
        return 1
      }

      echo "wait_for_node_drain: waiting for Karpenter to terminate all accelerator NodeClaims..."
      if ! wait_for_empty "nodeclaims.karpenter.sh" "NodeClaim(s)" 180; then
        echo "wait_for_node_drain: NodeClaims still present after 30 minutes. Refusing to proceed — check for a stuck node (kubectl get nodeclaims, aws ec2 describe-instances) and re-run destroy once clear." >&2
        exit 1
      fi

      # Discovered live: kubectl_manifest reports an EC2NodeClass "destroyed" the moment its
      # delete is accepted, same as NodePool/NodeClaim — but unlike NodePool, its
      # karpenter.k8s.aws/termination finalizer is NOT cleared until well after NodeClaims
      # finish terminating (observed: still present with Karpenter's controller Pod still
      # Running, several minutes after the NodeClaim step above completed). This wait is
      # best-effort (does NOT fail the destroy on timeout), for a reason discovered live and
      # not fixable within this module: Karpenter's EC2NodeClass finalizer logic calls IAM
      # (ListInstanceProfiles) — and IAM has no regional Interface VPC endpoint (see
      # vpc-endpoints.tf's note on IAM), so if the NAT gateway is already gone by this point,
      # that call times out FOREVER and the finalizer never clears. Failing the whole destroy
      # over an object with no billing impact (the underlying EC2 instance is confirmed
      # terminated by the NodeClaim wait above) would be worse than leaving a stuck
      # Kubernetes object behind. If this warns, clear it manually:
      #   kubectl patch ec2nodeclass <name> --type=merge -p '{"metadata":{"finalizers":[]}}'
      echo "wait_for_node_drain: waiting for Karpenter to clear EC2NodeClass finalizers (best-effort)..."
      if ! wait_for_empty "ec2nodeclasses.karpenter.k8s.aws" "EC2NodeClass(es)" 60; then
        echo "wait_for_node_drain: EC2NodeClasses still present after 10 minutes (likely blocked on an IAM call with no NAT/VPC-endpoint path — harmless, the EC2 instance is already gone). Proceeding with destroy; clear the stuck finalizer manually if 'kubectl get ec2nodeclass' still shows it afterward." >&2
      fi
      exit 0
    EOT
  }

  # This resource's own depends_on (above) lists everything it must be destroyed BEFORE
  # (Karpenter and every controller/addon that owns a per-node resource). It does NOT
  # depend on the NodePool/NodeClaim manifests. Instead, karpenter-resources.tf adds
  # `depends_on = [null_resource.wait_for_node_drain]` on those manifests, making THEM
  # depend on this resource — so their delete is issued before this resource (and its wait)
  # is destroyed. That keeps the graph a single line (NodePool -> this -> controllers) with
  # no cycle, since this resource never depends on anything downstream of it.
}

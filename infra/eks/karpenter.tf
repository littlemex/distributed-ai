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

  # The karpenter-crd chart exposes webhook.enabled to wire a CRD conversion webhook. Karpenter
  # removed the v1beta1->v1 conversion webhooks in v1.1, so on the version pinned here it is not
  # needed; disable it explicitly to keep the CRD schema plain.
  set {
    name  = "webhook.enabled"
    value = "false"
  }

  # Give the CRD uninstall more than the 300s helm default. By the time this chart is deleted,
  # null_resource.wait_for_node_drain has already stripped the nodepools/ec2nodeclasses
  # finalizers (see that resource), so the delete should be fast — but keep the headroom so a
  # momentarily slow API server does not trip "context deadline exceeded".
  timeout = 600

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
    cluster_name        = module.eks.cluster_name
    region              = var.region
    aws_profile         = var.aws_profile != null ? var.aws_profile : ""
    karpenter_namespace = local.karpenter_namespace
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
    # Kubeflow Trainer v2 controller: a TrainJob's worker pods run on accelerator (or CPU) nodes,
    # so on destroy the drain-wait must complete BEFORE the controller is torn down. (The v2.2.1
    # chart keeps CRDs in crds/, so uninstall leaves them — this edge is about draining pods, not
    # about a CRD/finalizer race.)
    helm_release.trainer,
    aws_eks_addon.efs_csi_driver,
    aws_eks_addon.fsx_csi_driver,
    helm_release.openzfs_csi_driver,
    aws_security_group.efa_node,
    # Same reason as efa_node above: on destroy the drain-wait must run BEFORE the placement
    # group is deleted (a PG cannot be deleted while instances are still in it). depends_on
    # here => destroy order is drain-wait first, then aws_placement_group.accelerator.
    aws_placement_group.accelerator,
    aws_vpc_endpoint.interface,
    aws_vpc_endpoint.s3,
    # S3 Files mount target (+ its SG): on destroy the drain-wait must finish BEFORE the NFS
    # endpoint is removed. A pod hard-mounting S3 Files whose mount target vanishes mid-drain
    # stalls kubelet's volume unmount, which stalls the drain, which times out and can leak the
    # NodeClaim/EC2 instance. efs.tf already protects the CSI driver for this reason; the mount
    # target (the other half — the NFS server) needs the same protection. No cycle: the mount
    # target depends only on the VPC subnet + SG, not on the cluster.
    aws_cloudcontrolapi_resource.s3files_mt,
    aws_security_group.s3files_mt,
    aws_vpc_security_group_ingress_rule.s3files_mt_from_nodes,
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
      if [ -n "${self.triggers.aws_profile}" ]; then PROFILE_ARGS=(--profile "${self.triggers.aws_profile}"); fi
      # Expand as $${PROFILE_ARGS[@]+"$${PROFILE_ARGS[@]}"}: this yields ZERO arguments when
      # the array is empty (no aws_profile — the default-profile / assumed-role case) and the
      # real --profile <name> args when set, and is safe under `set -u` on bash 3.2+ (macOS).
      # A plain "$${PROFILE_ARGS[@]}" trips "unbound variable" on old bash when empty, and the
      # "$${PROFILE_ARGS[@]:-}" workaround is WORSE: it passes a single empty-string argument
      # to the aws CLI, which fails with exit 252 — so the drain-wait would abort before it
      # polls NodeClaims (verified live in ap-northeast-1). Use the [@]+ form.
      KCONF=$(mktemp)
      trap 'rm -f "$KCONF"' EXIT
      if ! aws eks describe-cluster --name "${self.triggers.cluster_name}" --region "${self.triggers.region}" $${PROFILE_ARGS[@]+"$${PROFILE_ARGS[@]}"} >/dev/null 2>&1; then
        echo "wait_for_node_drain: cluster ${self.triggers.cluster_name} no longer exists, skipping drain wait"
        exit 0
      fi
      aws eks update-kubeconfig --name "${self.triggers.cluster_name}" --region "${self.triggers.region}" $${PROFILE_ARGS[@]+"$${PROFILE_ARGS[@]}"} --kubeconfig "$KCONF" >/dev/null 2>&1 \
        || { echo "wait_for_node_drain: cluster exists but update-kubeconfig failed — cannot verify drain. Check for orphaned EC2 instances manually." >&2; exit 1; }
      export KUBECONFIG="$KCONF"

      # Delete any Kubeflow Trainer v2 TrainJobs cluster-wide BEFORE waiting on NodeClaims. The
      # teardown script (scripts/04-teardown.sh) already does this for its namespace, but a bare
      # `terraform destroy` skips that script — without this, a TrainJob's JobSet-managed pods
      # keep accelerator nodes busy and the NodeClaim wait below runs to its timeout. Best-effort
      # (|| true) and time-boxed: a wedged Trainer controller that cannot clear finalizers must
      # not block teardown. If the CRD is already gone, `kubectl` errors harmlessly and we move on.
      echo "wait_for_node_drain: deleting any TrainJobs before draining (best-effort)..."
      kubectl delete trainjob --all --all-namespaces --ignore-not-found=true --timeout=120s 2>/dev/null || {
        echo "wait_for_node_drain: TrainJob delete errored or timed out (CRD absent, or controller wedged) — continuing."
        for tj in $(kubectl get trainjob --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null); do
          ns="$${tj%%/*}"; name="$${tj##*/}"
          kubectl -n "$ns" patch trainjob "$name" --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
        done
      }

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

      # ── HARD GATE: never touch any finalizer until this passes ──────────────────
      # Block until Karpenter has terminated every NodeClaim. A NodeClaim's
      # karpenter.sh/termination finalizer is the billing guarantee itself: Karpenter holds the
      # object until it has terminated the backing EC2 instance, then removes the finalizer and
      # the object disappears. So "nodeclaims = 0" IS "every Karpenter-managed EC2 is terminated".
      # We NEVER force-strip a NodeClaim finalizer — doing so erases a live instance from the
      # cluster's view while it keeps billing (observed live in ap-northeast-1: a g5 GPU node was
      # orphaned exactly this way). If this never reaches zero, we refuse to proceed.
      echo "wait_for_node_drain: waiting for Karpenter to terminate all accelerator NodeClaims..."
      if ! wait_for_empty "nodeclaims.karpenter.sh" "NodeClaim(s)" 180; then
        echo "wait_for_node_drain: NodeClaims still present after 30 minutes. Refusing to proceed — check for a stuck node (kubectl get nodeclaims, aws ec2 describe-instances) and re-run destroy once clear." >&2
        exit 1
      fi

      # ── Past the gate: nodeclaims == 0, so no Karpenter-managed EC2 instance exists ─────
      # Now clear the finalizers that block the CRD delete later. NodePool and EC2NodeClass carry
      # termination finalizers whose controller-side release calls IAM (ListInstanceProfiles).
      # IAM has no regional Interface VPC endpoint (see vpc-endpoints.tf), so once the NAT gateway
      # is gone that call times out forever and the finalizer never clears — the karpenter-crd
      # chart uninstall then hangs to its timeout ("context deadline exceeded"; observed live).
      #
      # First give the controller a graceful window to clear them itself: right now the controller
      # and the NAT are both still alive (this resource is destroyed BEFORE them), so the IAM call
      # should succeed and finalizers clear on their own in most runs.
      echo "wait_for_node_drain: waiting for Karpenter to clear NodePool/EC2NodeClass finalizers (graceful)..."
      np_ok=0; nc_ok=0
      wait_for_empty "nodepools.karpenter.sh" "NodePool(s)" 30 && np_ok=1
      wait_for_empty "ec2nodeclasses.karpenter.k8s.aws" "EC2NodeClass(es)" 30 && nc_ok=1

      # If either is still stuck (finalizer wedged on the IAM/NAT timeout), force it. This is SAFE
      # here and ONLY here: the hard gate above proved there is no backing EC2 instance, so
      # stripping these finalizers destroys no billing guarantee (unlike NodeClaim finalizers,
      # which we never touch). Stop the controller first so it cannot re-add what we strip, and
      # wait for its Pods to actually be gone (a fixed sleep leaves an in-flight reconcile free to
      # re-add the finalizer right after the patch).
      if [ "$np_ok" != "1" ] || [ "$nc_ok" != "1" ]; then
        echo "wait_for_node_drain: finalizers still present (IAM call wedged with no NAT path). Stopping controller and force-clearing NodePool/EC2NodeClass finalizers (safe: no backing EC2 remains)..."
        kubectl -n "${self.triggers.karpenter_namespace}" scale deploy -l app.kubernetes.io/name=karpenter --replicas=0 >/dev/null 2>&1 || true
        kubectl -n "${self.triggers.karpenter_namespace}" wait --for=delete pod -l app.kubernetes.io/name=karpenter --timeout=120s >/dev/null 2>&1 || true
        # nodeclaims intentionally omitted: the gate guarantees there are none, and force-stripping
        # a NodeClaim finalizer is the exact bug this rewrite removes.
        for kind in nodepools.karpenter.sh ec2nodeclasses.karpenter.k8s.aws; do
          for obj in $(kubectl get "$kind" -o name 2>/dev/null); do
            kubectl patch "$obj" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 \
              && echo "wait_for_node_drain: cleared finalizers on $obj" \
              || echo "wait_for_node_drain: could not clear $obj (continuing)" >&2
          done
        done
      fi

      # ── FINAL ASSERT: catch API-invisible Karpenter orphans ─────────────────────
      # kubectl can only see instances Kubernetes still tracks. A NodeClaim lost in a prior
      # half-finished destroy could leave an EC2 instance running that no CR references. The only
      # authoritative "no billing" check is EC2 itself. Scope the query to KARPENTER-managed
      # instances by the karpenter.sh/nodepool tag AND this cluster's ownership tag
      # (kubernetes.io/cluster/<name>=owned): the EKS managed system node group carries the
      # cluster ownership tag too but NOT karpenter.sh/nodepool, and those nodes are torn down by
      # their own managed-nodegroup resource later in this same destroy — filtering on the cluster
      # tag alone would false-positive on them and abort a healthy teardown (observed live). We
      # only assert on the pool Karpenter owns, which is where the orphan risk actually lives.
      echo "wait_for_node_drain: asserting no Karpenter-managed EC2 instances remain (tag-based)..."
      orphans=$(aws ec2 describe-instances --region "${self.triggers.region}" $${PROFILE_ARGS[@]+"$${PROFILE_ARGS[@]}"} \
        --filters "Name=tag-key,Values=karpenter.sh/nodepool" \
                  "Name=tag:kubernetes.io/cluster/${self.triggers.cluster_name},Values=owned" \
                  "Name=instance-state-name,Values=running,pending" \
        --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)
      if [ -n "$orphans" ]; then
        echo "wait_for_node_drain: ORPHANED Karpenter EC2 instances still running/pending for cluster ${self.triggers.cluster_name}: $orphans" >&2
        echo "wait_for_node_drain: these are billing but no longer tracked by any NodeClaim. Terminate them (aws ec2 terminate-instances --instance-ids $orphans) and re-run destroy." >&2
        exit 1
      fi
      echo "wait_for_node_drain: no Karpenter-managed EC2 instances remain."
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

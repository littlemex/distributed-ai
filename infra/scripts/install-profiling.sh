#!/usr/bin/env bash
# One-command, re-runnable installer for the profiling platform on an EXISTING infra/eks cluster.
#
# It wires the whole platform end to end: the shared data layer (trace bucket, S3 Files, managed
# MLflow tracking server, IAM roles), the cluster-side mount and ServiceAccounts, the Pod Identity
# associations for every namespace allowed to collect profiles, and the analysis/knowledge MCP
# servers. Terraform outputs are read by this script, never by the operator.
#
# Usage:
#   CLUSTER_NAME=my-cluster AWS_REGION=us-east-2 PRODUCER_NAMESPACES=team-a,team-b \
#     infra/scripts/install-profiling.sh
#
# Required:
#   CLUSTER_NAME          EKS cluster to wire (must already exist)
#   AWS_REGION            region of the cluster and of its trace bucket
#   PRODUCER_NAMESPACES   comma-separated namespaces whose workloads may collect profiles
#
# Optional:
#   DATA_LAYER_NAME       data layer to use (default "mcp"). One data layer serves many clusters: it
#                         owns the shared MLflow tracking server and the per-region trace buckets.
#                         Reuse is the default; creating one needs CREATE_DATA_LAYER=1.
#   CREATE_DATA_LAYER=1   allow creating a data layer that does not exist yet (first install)
#   ANALYSIS_DIGEST       digest of the analysis MCP image (default: resolve tag v1-nsys)
#   KNOWLEDGE_DIGEST      digest of the knowledge MCP image (default: resolve tag v1)
#   DEV_BUILD=1           build both images in-cluster instead of using published digests
#   ALLOW_UNRELATED=1     apply cluster changes unrelated to profiling (default: stop and report)
#   PROFILING_ONLY=1      apply ONLY the profiling addresses, leaving unrelated drift untouched
#   SKIP_ACCEPTANCE=1     skip the final MCP round-trip check
#   AWS_PROFILE           passed through to aws/terraform as usual
#
# Re-running is safe: every phase is either natively idempotent or check-then-act. The script never
# destroys anything and never rolls back — on failure, fix the cause and run it again.
set -euo pipefail

# Resolved from this script's own location so it works from any working directory. It lives in
# infra/scripts because it orchestrates BOTH Terraform states: neither infra/eks nor
# infra/data-layer owns it.
infra_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
eks_dir="${infra_dir}/eks"
data_dir="${infra_dir}/data-layer"
work_dir="$(mktemp -d)"
cleanup() { [ -n "${pf_pid:-}" ] && kill "${pf_pid}" 2>/dev/null || true; rm -rf "${work_dir}"; }
trap cleanup EXIT

usage() { sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
say() { printf '\n==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ "${1:-}" = "-h" ] && usage 0

# ── the profiling platform's own terraform addresses in infra/eks ───────────────────────────────
# Everything the platform owns on the cluster side. Used both to classify a plan (anything else is
# unrelated drift) and, with PROFILING_ONLY=1, to apply only these.
profiling_addresses() {
  cat <<'ADDR'
aws_cloudcontrolapi_resource.s3files_mt
aws_security_group.s3files_mt
aws_vpc_security_group_ingress_rule.s3files_mt_from_nodes
aws_iam_role_policy.efs_csi_s3files
aws_iam_role_policy.efs_csi_node_s3files
kubectl_manifest.mcp_namespace
kubectl_manifest.mcp_reader_sa
aws_eks_pod_identity_association.mcp_reader
aws_eks_pod_identity_association.producer
aws_ecr_repository.profiling
aws_ecr_lifecycle_policy.profiling
ADDR
}

# Resources whose destruction loses the record of record. A plan that deletes or replaces one of
# these is refused outright: the trace bucket and the tracking server hold the profiling history,
# and losing run metadata makes every stored prefix look orphaned to a garbage collector.
protected_addresses() {
  cat <<'ADDR'
aws_s3_bucket.traces
aws_s3_bucket.mlflow_artifacts
aws_sagemaker_mlflow_tracking_server.this
aws_kms_key.data
aws_cloudcontrolapi_resource.s3files_fs
aws_cloudcontrolapi_resource.s3files_ap
ADDR
}

# ── plan guard ─────────────────────────────────────────────────────────────────────────────────
# Never applies blind. Classifies every planned change into protected / owned / unrelated and stops
# unless the operator has said what to do about the unrelated ones.
# Set by guard_plan: the plan file it inspected. Applying this exact file, rather than re-planning,
# is what makes the guard meaningful — otherwise the applied plan is not the plan that was checked.
guarded_plan=""

guard_plan() {
  local dir="$1" label="$2"; shift 2
  local plan_file="${work_dir}/${label}.tfplan"
  guarded_plan="${plan_file}"
  say "planning ${label}"
  terraform -chdir="${dir}" plan -input=false -lock-timeout=5m -out="${plan_file}" "$@" >/dev/null
  terraform -chdir="${dir}" show -json "${plan_file}" >"${plan_file}.json"
  profiling_addresses >"${work_dir}/owned.txt"
  protected_addresses >"${work_dir}/protected.txt"
  ALLOW_UNRELATED="${ALLOW_UNRELATED:-0}" PROFILING_ONLY="${PROFILING_ONLY:-0}" LABEL="${label}" \
    python3 - "${plan_file}.json" "${work_dir}/owned.txt" "${work_dir}/protected.txt" <<'PY'
import json, os, re, sys

plan = json.load(open(sys.argv[1]))
owned = [l.strip() for l in open(sys.argv[2]) if l.strip()]
protected = [l.strip() for l in open(sys.argv[3]) if l.strip()]
label = os.environ["LABEL"]

def base(addr):
    # strip module path and index so "module.x.aws_s3_bucket.traces[\"a\"]" matches "aws_s3_bucket.traces"
    no_index = re.sub(r'\[[^\]]*\]', '', addr)
    return no_index.split('.', 2)[-1] if no_index.startswith('module.') else no_index

# A delete is unrecoverable, and a create of a resource that is supposed to already exist means the
# state has lost track of it: applying that either fails on a name collision or, worse, reconfigures
# something the state no longer describes. Both are refused.
destructive = {"delete"}
buckets = {"protected": [], "recreate": [], "owned": [], "unrelated": []}
for rc in plan.get("resource_changes", []):
    actions = [a for a in rc["change"]["actions"] if a != "no-op"]
    if not actions or actions == ["read"]:
        continue
    b = base(rc["address"])
    verb = "+".join(actions)
    if b in protected and destructive.intersection(actions):
        buckets["protected"].append(f"{rc['address']} ({verb})")
    elif b in protected and "create" in actions:
        buckets["recreate"].append(f"{rc['address']} ({verb})")
    elif b in owned or b in protected:
        buckets["owned"].append(f"{rc['address']} ({verb})")
    else:
        buckets["unrelated"].append(f"{rc['address']} ({verb})")

for kind in ("protected", "recreate", "owned", "unrelated"):
    for item in buckets[kind]:
        print(f"    [{kind}] {item}")
if not any(buckets.values()):
    print("    no changes")

if buckets["protected"]:
    sys.exit(f"error: the {label} plan would destroy record-of-record resources; refusing. "
             "Resolve this by hand — this script never destroys data.")
if buckets["recreate"]:
    sys.exit(f"error: the {label} plan would CREATE record-of-record resources that should already "
             "exist (listed above), which means this state no longer tracks them. Applying it would "
             "collide with the live resource instead of adopting it. Import them into the state "
             "first; the installer adopts the known ones automatically, so this indicates a case it "
             "does not cover yet.")
if buckets["unrelated"] and os.environ["ALLOW_UNRELATED"] != "1" and os.environ["PROFILING_ONLY"] != "1":
    sys.exit(f"error: the {label} plan contains {len(buckets['unrelated'])} change(s) unrelated to "
             "profiling (listed above). This is pre-existing cluster drift, not something this "
             "installer introduced. Re-run with PROFILING_ONLY=1 to apply only the profiling "
             "resources, or ALLOW_UNRELATED=1 to apply everything.")
PY
}

# ── inputs ─────────────────────────────────────────────────────────────────────────────────────
: "${CLUSTER_NAME:?set CLUSTER_NAME to the existing EKS cluster to wire}"
: "${AWS_REGION:?set AWS_REGION to the cluster region}"
: "${PRODUCER_NAMESPACES:?set PRODUCER_NAMESPACES to a comma-separated namespace list}"
DATA_LAYER_NAME="${DATA_LAYER_NAME:-mcp}"

for tool in terraform kubectl helm aws python3 curl; do
  command -v "$tool" >/dev/null || die "$tool is required but not on PATH"
done

# Every kubectl and helm call names the context explicitly. An account usually holds several
# clusters, and a wrong current-context silently wires the wrong one.
KCTX="profiling-${CLUSTER_NAME}"

IFS=',' read -r -a ns_array <<<"${PRODUCER_NAMESPACES}"
ns_json="$(printf '%s\n' "${ns_array[@]}" |
  python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
[ "${ns_json}" = "[]" ] && die "PRODUCER_NAMESPACES parsed to an empty list"

# ── phase 1: preflight ─────────────────────────────────────────────────────────────────────────
say "Phase 1/7: preflight"
aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
  --query 'cluster.status' --output text >/dev/null 2>&1 ||
  die "cluster ${CLUSTER_NAME} not found in ${AWS_REGION}; this installer wires an existing cluster"
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}" --alias "${KCTX}" >/dev/null
kubectl --context "${KCTX}" get --raw /version >/dev/null || die "cannot reach ${CLUSTER_NAME} with kubectl"

account_id="$(aws sts get-caller-identity --query Account --output text)"
ecr_registry="${account_id}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# A Pod Identity association does not require its namespace to exist, so a missing namespace is a
# warning: wiring before the workload lands is a supported order.
for ns in "${ns_array[@]}"; do
  kubectl --context "${KCTX}" get namespace "${ns}" >/dev/null 2>&1 ||
    warn "namespace '${ns}' does not exist yet; its association is created and stays dormant until it does"
done

[ -f "${eks_dir}/backend.hcl" ] ||
  die "${eks_dir}/backend.hcl not found; run infra/eks/scripts/bootstrap-remote-state.sh first (local state is not supported here)"
tf_val() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\{0,1\}\([^\"]*\)\"\{0,1\}[[:space:]]*$/\1/p" "${eks_dir}/backend.hcl" | head -1; }
state_bucket="$(tf_val bucket)"
state_region="$(tf_val region)"
lock_table="$(tf_val dynamodb_table)"
[ -n "${state_bucket}" ] && [ -n "${state_region}" ] ||
  die "could not read bucket and region from ${eks_dir}/backend.hcl"
data_state_key="data-layer/${DATA_LAYER_NAME}/terraform.tfstate"

# ── phase 2: data layer ────────────────────────────────────────────────────────────────────────
say "Phase 2/7: data layer '${DATA_LAYER_NAME}' at s3://${state_bucket}/${data_state_key}"

# Creating a second data layer by accident splits the platform in two, so an absent state is only
# created when the operator asks for it.
if ! aws s3api head-object --bucket "${state_bucket}" --key "${data_state_key}" \
  --region "${state_region}" >/dev/null 2>&1; then
  [ "${CREATE_DATA_LAYER:-0}" = "1" ] ||
    die "no data layer state at s3://${state_bucket}/${data_state_key}. Point DATA_LAYER_NAME at an existing data layer, or pass CREATE_DATA_LAYER=1 to create a new one."
  say "creating a new data layer (CREATE_DATA_LAYER=1)"
fi

# The data layer ships its S3 backend as an example file so that a plain `terraform init` still
# works on a sandbox. Remote state is mandatory here: this state owns the record of record, and a
# lost local state file leaves prevent_destroy buckets stranded.
if [ ! -f "${data_dir}/backend.tf" ]; then
  say "installing ${data_dir}/backend.tf from the shipped example"
  cp "${data_dir}/backend.tf.example" "${data_dir}/backend.tf"
fi

data_backend=(
  -backend-config="bucket=${state_bucket}"
  -backend-config="key=${data_state_key}"
  -backend-config="region=${state_region}"
  -backend-config="encrypt=true"
)
[ -n "${lock_table}" ] && data_backend+=(-backend-config="dynamodb_table=${lock_table}")
terraform -chdir="${data_dir}" init -reconfigure -input=false "${data_backend[@]}" >/dev/null

data_vars=(
  -var "region=${AWS_REGION}"
  -var "name_prefix=${DATA_LAYER_NAME}"
  -var "trace_regions=[\"${AWS_REGION}\"]"
  -var "s3files_trace_region=${AWS_REGION}"
  -var "s3files_enabled=true"
  -var "mlflow_enabled=true"
)
# A record-of-record bucket that exists in AWS but not in this state must be adopted, never
# re-created: a create either collides on the name or silently reconfigures a bucket the state does
# not describe. The sub-resources take the bucket name as their import id.
adopt_bucket() {
  local bucket="$1" suffix="$2"
  aws s3api head-bucket --bucket "${bucket}" >/dev/null 2>&1 || return 0
  local state_list addr
  state_list="$(terraform -chdir="${data_dir}" state list 2>/dev/null || true)"
  for addr in "aws_s3_bucket.${suffix}" "aws_s3_bucket_versioning.${suffix}" \
    "aws_s3_bucket_server_side_encryption_configuration.${suffix}" \
    "aws_s3_bucket_public_access_block.${suffix}"; do
    printf '%s\n' "${state_list}" | grep -qF "${addr}" && continue
    # A missing sub-resource may simply never have been configured on the bucket, in which case the
    # import fails and the plan creates it — which is correct for a configuration, not for a bucket.
    if terraform -chdir="${data_dir}" import -input=false -lock-timeout=5m "${data_vars[@]}" \
      "${addr}" "${bucket}" >/dev/null 2>&1; then
      say "adopted ${addr} for the existing bucket ${bucket}"
    fi
  done
}
adopt_bucket "${DATA_LAYER_NAME}-mlflow-artifacts-${account_id}" "mlflow_artifacts"
adopt_bucket "${DATA_LAYER_NAME}-traces-${AWS_REGION}-${account_id}" "traces[\"${AWS_REGION}\"]"

guard_plan "${data_dir}" "data-layer" "${data_vars[@]}"
terraform -chdir="${data_dir}" apply -input=false -auto-approve -lock-timeout=5m "${guarded_plan}" >/dev/null

dl_out() { terraform -chdir="${data_dir}" output -raw "$1"; }
mlflow_arn="$(dl_out mlflow_app_arn)"
reader_role="$(dl_out mcp_reader_role_arn)"
producer_role="$(dl_out producer_role_arn)"
s3files_fs="$(dl_out s3files_file_system_id)"
volume_handle="$(dl_out s3files_volume_handle)"
trace_bucket="$(terraform -chdir="${data_dir}" output -json trace_buckets |
  python3 -c "import json,os,sys; print(json.load(sys.stdin)[os.environ['AWS_REGION']])")"

for pair in "mlflow_app_arn=${mlflow_arn}" "mcp_reader_role_arn=${reader_role}" \
  "producer_role_arn=${producer_role}" "s3files_file_system_id=${s3files_fs}" \
  "s3files_volume_handle=${volume_handle}" "trace_bucket=${trace_bucket}"; do
  [ -n "${pair#*=}" ] || die "data layer output ${pair%%=*} came back empty"
done

# The scoped producer and reader roles authorize sagemaker-mlflow:* against an mlflow-tracking-server
# resource. A serverless MLflow App ARN would leave every data-plane call at 403.
case "${mlflow_arn}" in
  *:mlflow-tracking-server/*) : ;;
  *) die "MLflow ARN ${mlflow_arn} is not a tracking server ARN; scoped roles cannot reach an mlflow-app data plane" ;;
esac

# ── phase 3: cluster wiring ────────────────────────────────────────────────────────────────────
say "Phase 3/7: cluster wiring (S3 Files mount, mcp namespace, mcp-reader, producer associations, ECR)"
terraform -chdir="${eks_dir}" init -backend-config=backend.hcl -input=false >/dev/null

eks_vars=(
  -var "s3files_enabled=true"
  -var "s3files_file_system_id=${s3files_fs}"
  -var "analysis_mcp_enabled=true"
  -var "mcp_reader_role_arn=${reader_role}"
  -var "mcp_producer_role_arn=${producer_role}"
  -var "mcp_producer_namespaces=${ns_json}"
)

# An image repository that already exists outside the state would make apply fail with
# RepositoryAlreadyExists, which is the normal situation on a cluster that published images before
# the repositories became managed here. Adopt them instead of failing.
eks_state="$(terraform -chdir="${eks_dir}" state list 2>/dev/null || true)"
for repo in accelprof accelprof-knowledge; do
  aws ecr describe-repositories --repository-names "${repo}" --region "${AWS_REGION}" >/dev/null 2>&1 || continue
  printf '%s\n' "${eks_state}" | grep -qF "aws_ecr_repository.profiling[\"${repo}\"]" && continue
  say "adopting the existing ECR repository ${repo} into the cluster state"
  terraform -chdir="${eks_dir}" import -input=false -lock-timeout=5m "${eks_vars[@]}" \
    "aws_ecr_repository.profiling[\"${repo}\"]" "${repo}" >/dev/null
done

guard_plan "${eks_dir}" "cluster" "${eks_vars[@]}"
if [ "${PROFILING_ONLY:-0}" = "1" ]; then
  say "narrowing to the profiling addresses (PROFILING_ONLY=1)"
  targets=()
  while read -r addr; do [ -n "${addr}" ] && targets+=(-target="${addr}"); done < <(profiling_addresses)
  # The narrowed plan is a different plan, so it is inspected in its own right before being applied.
  guard_plan "${eks_dir}" "cluster-targeted" "${targets[@]}" "${eks_vars[@]}"
fi
terraform -chdir="${eks_dir}" apply -input=false -auto-approve -lock-timeout=5m "${guarded_plan}" >/dev/null
mount_zone="$(terraform -chdir="${eks_dir}" output -raw s3files_mount_target_az)"
[ -n "${mount_zone}" ] || die "s3files_mount_target_az output came back empty"
say "S3 Files mount is reachable from ${mount_zone} only; the MCP pods are pinned there"

# ── phase 4: images ────────────────────────────────────────────────────────────────────────────
say "Phase 4/7: images"
ecr_digest() {
  aws ecr describe-images --repository-name "$1" --image-ids "imageTag=$2" \
    --query 'imageDetails[0].imageDigest' --output text --region "${AWS_REGION}" 2>/dev/null || true
}
if [ "${DEV_BUILD:-0}" = "1" ]; then
  # The build path runs on the cluster's rootless BuildKit, which infra/eks provisions behind
  # image_builder_enabled. Without it there is no image-builder namespace to build in.
  kubectl --context "${KCTX}" get namespace image-builder >/dev/null 2>&1 ||
    die "DEV_BUILD=1 needs the in-cluster image builder; apply infra/eks with image_builder_enabled=true first"
  say "building the images in-cluster (DEV_BUILD=1)"
  KCTX="${KCTX}" AWS_REGION="${AWS_REGION}" ECR_REGISTRY="${ecr_registry}" \
    "${eks_dir}/scripts/build-profiling-images.sh"
fi
analysis_digest="${ANALYSIS_DIGEST:-$(ecr_digest accelprof v1-nsys)}"
knowledge_digest="${KNOWLEDGE_DIGEST:-$(ecr_digest accelprof-knowledge v1)}"
case "${analysis_digest}" in sha256:*) : ;; *) die "no analysis image digest available; pass ANALYSIS_DIGEST or use DEV_BUILD=1" ;; esac
case "${knowledge_digest}" in sha256:*) : ;; *) die "no knowledge image digest available; pass KNOWLEDGE_DIGEST or use DEV_BUILD=1" ;; esac
say "analysis  ${analysis_digest}"
say "knowledge ${knowledge_digest}"

# ── phase 5: MCP servers ───────────────────────────────────────────────────────────────────────
say "Phase 5/7: deploying the MCP servers"
values_file="${work_dir}/mcp-host-values.yaml"
cat >"${values_file}" <<VALUES
mcps:
  - name: knowledge
    transport: http
    image:
      repository: "${ecr_registry}/accelprof-knowledge"
      digest: "${knowledge_digest}"
    command: ["accelprof-knowledge-mcp"]
  - name: analysis
    transport: http
    image:
      repository: "${ecr_registry}/accelprof"
      digest: "${analysis_digest}"
    command: ["accelprof-analysis-mcp"]
    serviceAccountName: mcp-reader
    env:
      MCP_MLFLOW_TRACKING_URI: "${mlflow_arn}"
      MCP_AWS_REGION: "${AWS_REGION}"
      MCP_TRACE_BUCKET: "${trace_bucket}"
      MCP_MOUNT_BASE: "/traces"
    resources:
      requests: { cpu: "250m", memory: "512Mi" }
      limits: { memory: "2Gi" }
    s3files:
      enabled: true
      volumeHandle: "${volume_handle}"
      mountBase: "/traces"
      zone: "${mount_zone}"
VALUES
helm dependency build "${eks_dir}/charts/mcp-host" >/dev/null
generated="${eks_dir}/charts/mcp-host/values-${CLUSTER_NAME}.generated.yaml"
if [ -f "${generated}" ] && ! diff -q "${generated}" "${values_file}" >/dev/null; then
  say "values changed since the last run:"
  diff -u "${generated}" "${values_file}" || true
fi
helm --kube-context "${KCTX}" upgrade --install mcp "${eks_dir}/charts/mcp-host" \
  -n mcp -f "${values_file}" --wait --timeout 10m >/dev/null
cp "${values_file}" "${generated}"
say "deployed; the generated values are kept at ${generated}"

# ── phase 5b: the producer contract in each namespace ──────────────────────────────────────────
# A profiling workload should not have to know the bucket, the tracking server or the platform image.
# Publishing them as a ConfigMap in every producer namespace is what lets scripts/profile-run.sh take
# only an alias, an image and a command. The Role lets the recorder read its own Pod's status, which
# is how an untrappable kill (an OOM) still becomes a recorded failure rather than a timeout.
say "Phase 5b/7: publishing the producer contract to ${PRODUCER_NAMESPACES}"
for ns in "${ns_array[@]}"; do
  if ! kubectl --context "${KCTX}" get namespace "${ns}" >/dev/null 2>&1; then
    warn "namespace '${ns}' does not exist yet; its accelprof-config will be published on a later run"
    continue
  fi
  kubectl --context "${KCTX}" create configmap accelprof-config -n "${ns}" \
    --from-literal="ACCELPROF_REGION=${AWS_REGION}" \
    --from-literal="ACCELPROF_TRACE_BUCKET=${trace_bucket}" \
    --from-literal="ACCELPROF_TRACKING_URI=${mlflow_arn}" \
    --from-literal="ACCELPROF_PLATFORM_IMAGE=${ecr_registry}/accelprof@${analysis_digest}" \
    --dry-run=client -o yaml | kubectl --context "${KCTX}" apply -f - >/dev/null
  cat <<RBAC | kubectl --context "${KCTX}" apply -f - >/dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: accelprof-producer, namespace: ${ns} }
rules:
  # The recorder reads its own Pod so that an untrappable kill becomes a recorded failure rather than
  # a timeout, and annotates its own Job with the run id so it can be found without reading logs.
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get"]
  - apiGroups: ["batch"]
    resources: ["jobs"]
    verbs: ["get", "list", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: accelprof-producer, namespace: ${ns} }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: accelprof-producer }
subjects:
  - kind: ServiceAccount
    name: mcp-producer
    namespace: ${ns}
RBAC
  # No controller reconciles producer Jobs, by design: each Job records itself from inside its Pod.
  # The one gap that leaves is a Pod that disappears before recording (eviction, node drain, a killed
  # recorder), which nothing in the Pod can report. This CronJob is monitoring for exactly that: it
  # lists finished producer Jobs with no run id and fails when it finds any.
  cat <<CRON | kubectl --context "${KCTX}" apply -f - >/dev/null
apiVersion: batch/v1
kind: CronJob
metadata: { name: accelprof-orphan-check, namespace: ${ns} }
spec:
  schedule: "17 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 0
      ttlSecondsAfterFinished: 86400
      template:
        spec:
          restartPolicy: Never
          serviceAccountName: mcp-producer
          containers:
            - name: check
              image: ${ecr_registry}/accelprof@${analysis_digest}
              command: ["python3","/opt/accelprof/orphan-check.py"]
              env:
                - name: POD_NAMESPACE
                  valueFrom: { fieldRef: { fieldPath: metadata.namespace } }
              resources:
                requests: { cpu: "50m", memory: "128Mi" }
                limits: { memory: "256Mi" }
CRON
  say "  ${ns}: accelprof-config, the recorder Role and the orphan check are in place"
done

# ── phase 6: mount probe ───────────────────────────────────────────────────────────────────────
# Whether the read-only S3 Files mount actually works is decided by the EFS CSI node plugin, which
# receives its Pod Identity credentials only when its Pod starts. Probing is decisive and cheap, so
# it runs every time instead of tracking "first install" state.
say "Phase 6/7: mount probe"
probe_pvc="$(kubectl --context "${KCTX}" get pvc -n mcp \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
probe_mount() {
  kubectl --context "${KCTX}" delete job mcp-mount-probe -n mcp --ignore-not-found >/dev/null 2>&1 || true
  # The mcp namespace enforces the restricted Pod Security Standard, so the probe carries the full
  # restricted securityContext. Without it the Job is admitted but its pods are rejected, which
  # looks exactly like a mount failure and would trigger a pointless DaemonSet restart.
  cat <<PROBE | kubectl --context "${KCTX}" apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata: { name: mcp-mount-probe, namespace: mcp }
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      nodeSelector: { topology.kubernetes.io/zone: ${mount_zone} }
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        runAsGroup: 65534
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: probe
          image: public.ecr.aws/docker/library/busybox:1.36
          command: ["sh","-c","ls /traces >/dev/null && echo MOUNT_OK"]
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
          volumeMounts: [{ name: traces, mountPath: /traces, readOnly: true }]
      volumes:
        - name: traces
          persistentVolumeClaim: { claimName: ${probe_pvc} }
PROBE
  kubectl --context "${KCTX}" wait --for=condition=complete job/mcp-mount-probe -n mcp --timeout=180s >/dev/null 2>&1
}

# Why the probe failed decides what to do next. Only a genuine mount failure justifies touching the
# shared EFS CSI DaemonSet; an admission rejection or an unschedulable pod must surface as-is.
probe_failure_is_mount_related() {
  local phase reason
  phase="$(kubectl --context "${KCTX}" get pods -n mcp -l job-name=mcp-mount-probe \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
  if [ -z "${phase}" ]; then
    warn "the probe pod was never created; the Job was likely rejected by admission"
    kubectl --context "${KCTX}" describe job mcp-mount-probe -n mcp 2>/dev/null | tail -12 >&2
    return 1
  fi
  reason="$(kubectl --context "${KCTX}" get events -n mcp \
    --field-selector involvedObject.kind=Pod -o json 2>/dev/null |
    python3 -c 'import json,sys
try: ev=json.load(sys.stdin).get("items",[])
except Exception: ev=[]
print(" ".join(e.get("reason","")+":"+e.get("message","") for e in ev if "mcp-mount-probe" in e.get("involvedObject",{}).get("name","")))' 2>/dev/null || true)"
  case "${reason}" in
    *FailedMount*|*FailedAttachVolume*|*mount.nfs*|*access\ denied*) return 0 ;;
  esac
  if [ "${phase}" = "Pending" ]; then
    warn "the probe pod is Pending, so this is scheduling, not mounting: ${reason}"
    return 1
  fi
  warn "the probe failed without a mount error: phase=${phase} ${reason}"
  return 1
}
if [ -z "${probe_pvc}" ]; then
  warn "no S3 Files PVC in namespace mcp; skipping the probe"
elif probe_mount; then
  say "mount probe OK"
  kubectl --context "${KCTX}" annotate ds efs-csi-node -n kube-system \
    "mcp/s3files-fs=${s3files_fs}" --overwrite >/dev/null
else
  probe_failure_is_mount_related ||
    die "the mount probe failed for a reason unrelated to mounting (see above); not touching the shared EFS CSI DaemonSet"
  # The DaemonSet is shared with every other EFS volume on the cluster, so it is restarted only when
  # it has not yet seen this filesystem — never unconditionally.
  seen="$(kubectl --context "${KCTX}" get ds efs-csi-node -n kube-system \
    -o jsonpath='{.metadata.annotations.mcp/s3files-fs}' 2>/dev/null || true)"
  [ "${seen}" = "${s3files_fs}" ] &&
    die "mount probe failed and the EFS CSI node plugin already saw ${s3files_fs}; inspect job/mcp-mount-probe in namespace mcp"
  say "probe failed and the node plugin has not seen ${s3files_fs} yet; restarting it once"
  kubectl --context "${KCTX}" rollout restart ds/efs-csi-node -n kube-system >/dev/null
  kubectl --context "${KCTX}" rollout status ds/efs-csi-node -n kube-system --timeout=300s >/dev/null
  kubectl --context "${KCTX}" annotate ds efs-csi-node -n kube-system \
    "mcp/s3files-fs=${s3files_fs}" --overwrite >/dev/null
  probe_mount || die "mount still failing after restarting the EFS CSI node plugin; inspect job/mcp-mount-probe in namespace mcp"
  say "mount probe OK after the restart"
fi
kubectl --context "${KCTX}" delete job mcp-mount-probe -n mcp --ignore-not-found >/dev/null 2>&1 || true

# ── phase 7: acceptance ────────────────────────────────────────────────────────────────────────
if [ "${SKIP_ACCEPTANCE:-0}" = "1" ]; then
  say "Phase 7/7: acceptance skipped (SKIP_ACCEPTANCE=1)"
else
  say "Phase 7/7: acceptance, an MCP round trip against the analysis server"
  kubectl --context "${KCTX}" wait --for=condition=Available deploy -l role=mcp-host -n mcp --timeout=300s >/dev/null
  port=18080
  kubectl --context "${KCTX}" port-forward svc/analysis -n mcp "${port}:8080" >"${work_dir}/pf.log" 2>&1 &
  pf_pid=$!
  ct='Content-Type: application/json'
  ac='Accept: application/json, text/event-stream'
  init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"installer","version":"1"}}}'
  ready=0
  for _ in $(seq 1 20); do
    if curl -sf -o /dev/null -H "${ct}" -H "${ac}" -X POST "http://127.0.0.1:${port}/mcp" -d "${init}"; then
      ready=1; break
    fi
    sleep 2
  done
  [ "${ready}" = "1" ] || die "analysis MCP did not answer on the forwarded port"
  curl -s -D "${work_dir}/hdr.txt" -o /dev/null -H "${ct}" -H "${ac}" \
    -X POST "http://127.0.0.1:${port}/mcp" -d "${init}"
  sid="$(awk 'tolower($1)=="mcp-session-id:"{print $2}' "${work_dir}/hdr.txt" | tr -d '\r')"
  [ -n "${sid}" ] || die "analysis MCP returned no session id"
  curl -s -o /dev/null -H "${ct}" -H "${ac}" -H "mcp-session-id: ${sid}" \
    -X POST "http://127.0.0.1:${port}/mcp" -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  tools="$(curl -s -H "${ct}" -H "${ac}" -H "mcp-session-id: ${sid}" \
    -X POST "http://127.0.0.1:${port}/mcp" -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' |
    tr -d '\r' | sed -n 's/^data: //p' |
    python3 -c 'import json,sys; d=json.load(sys.stdin); print(",".join(t["name"] for t in d["result"]["tools"]))')"
  case "${tools}" in
    *analyze*) say "acceptance OK: the analysis server exposes ${tools}" ;;
    *) die "the analysis server did not expose analyze (got: ${tools:-nothing})" ;;
  esac
fi

cat <<SUMMARY

Profiling platform ready on ${CLUSTER_NAME}.

  MLflow tracking server : ${mlflow_arn}
  Trace bucket           : ${trace_bucket}
  Mount zone             : ${mount_zone}
  Producer namespaces    : ${PRODUCER_NAMESPACES}
  kubectl context        : ${KCTX}

In each producer namespace, create the ServiceAccount the association targets:

  kubectl --context ${KCTX} create serviceaccount mcp-producer -n <namespace>

A Pod using that ServiceAccount records a run with:

  store.log("<tenant>-<series>", chip="gpu", region="${AWS_REGION}", workload_id="<variant>",
            metrics={...}, artifacts=["/path/to/trace.nsys-rep"])

The alias is the deletion, retention and visibility unit: use one alias per experiment campaign and
vary workload_id and free-form params inside it. See infra/PROFILING-INSTALL.md.
SUMMARY

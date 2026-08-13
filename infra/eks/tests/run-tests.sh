#!/usr/bin/env bash
# run-tests.sh — EKS infra-layer regression tests
# shellcheck disable=SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/suites.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/resolve.sh"

NAMESPACE="${NAMESPACE:-distai-test}"
CLUSTER_NAME="${CLUSTER_NAME:-}"
AWS_REGION_OPT="${AWS_REGION:-}"
AWS_PROFILE_OPT="${AWS_PROFILE:-}"
SUITE="baseline"
EXTRA_LAYERS=""
SKIP_LAYERS=""
KEEP_NS=false
LIST_ONLY=false
TIMEOUT_STATIC=120
TIMEOUT_BASE=60
TIMEOUT_GPU=600
GPU_COUNT=1
GPU_NODEPOOL="${GPU_NODEPOOL:-}"

# Manifest envsubst target variables (explicit list to avoid clobbering $TOKEN in Pod scripts).
# shellcheck disable=SC2016
ENVSUBST_VARS='${NAMESPACE} ${FSX_VOLUME_HANDLE} ${FSX_DNS_NAME} ${FSX_MOUNT_NAME} ${OPENZFS_VOLUME_HANDLE} ${OPENZFS_DNS_NAME} ${GPU_COUNT} ${GPU_NODEPOOL} ${FSX_TEST_PV_NAME} ${OPENZFS_TEST_PV_NAME}'

usage() {
  cat <<'USAGE'
Usage: ./run-tests.sh [options]

Suites:
  --suite baseline|coverage|full  Select the tiered suite (default: baseline)
  --suite neuron                 Standalone Trainium (vLLM Neuron plugin) suite; runs ONLY the
                                 neuron layer and is never included in baseline/coverage/full
  --with-gpu                     Compatibility alias: include the gpu layer
  --with-hardening               Compatibility alias: run at least coverage
  --skip-static                  Compatibility alias: skip the static layer

Options:
  --skip-layer LAYER             Skip static, live-ro, live-mut, gpu, or neuron (repeatable)
  --list                         Print the registry table and exit
  --keep-ns                      Keep the test namespace for inspection
  --namespace NAME               Test namespace
  --cluster-name NAME            Override derived cluster name
  --region REGION                Override derived AWS region
  --profile PROFILE              AWS CLI profile
  --gpu-count N                  GPU count requested by the smoke pod
  --gpu-nodepool NAME            Override derived NVIDIA NodePool
  --timeout-static SEC           Static test timeout
  --timeout-base SEC             Base live test timeout
  --timeout-gpu SEC              GPU test timeout
USAGE
}

need_arg() {
  if [ "$#" -lt 2 ] || [ -z "${2:-}" ] || [[ "$2" == --* ]]; then
    echo "Missing argument for $1" >&2
    usage >&2
    exit 1
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --suite)          need_arg "$@"; SUITE="$2"; shift 2 ;;
    --with-gpu)       EXTRA_LAYERS="$EXTRA_LAYERS gpu"; shift ;;
    --with-hardening) [ "$(suite_rank "$SUITE")" -lt "$(suite_rank coverage)" ] && SUITE=coverage; shift ;;
    --skip-static)    SKIP_LAYERS="$SKIP_LAYERS static"; shift ;;
    --skip-layer)     need_arg "$@"; valid_layer "$2" || { echo "Unknown layer: $2 (expected static|live-ro|live-mut|gpu)" >&2; exit 1; }; SKIP_LAYERS="$SKIP_LAYERS $2"; shift 2 ;;
    --list)           LIST_ONLY=true; shift ;;
    --keep-ns)        KEEP_NS=true; shift ;;
    --namespace)      need_arg "$@"; NAMESPACE="$2"; shift 2 ;;
    --cluster-name)   need_arg "$@"; CLUSTER_NAME="$2"; shift 2 ;;
    --region)         need_arg "$@"; AWS_REGION_OPT="$2"; shift 2 ;;
    --profile)        need_arg "$@"; AWS_PROFILE_OPT="$2"; shift 2 ;;
    --gpu-count)      need_arg "$@"; GPU_COUNT="$2"; shift 2 ;;
    --gpu-nodepool)   need_arg "$@"; GPU_NODEPOOL="$2"; shift 2 ;;
    --timeout-static) need_arg "$@"; TIMEOUT_STATIC="$2"; shift 2 ;;
    --timeout-base)   need_arg "$@"; TIMEOUT_BASE="$2"; shift 2 ;;
    --timeout-gpu)    need_arg "$@"; TIMEOUT_GPU="$2"; shift 2 ;;
    --help|-h)        usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

valid_suite "$SUITE" || { echo "Unknown suite: $SUITE" >&2; exit 1; }

# shellcheck disable=SC1091
source "$SCRIPT_DIR/cases/static.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/cases/base.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/cases/gpu.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/cases/neuron.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/cases/image-build.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/registry.sh"
register_all_tests

list_tests() {
  printf "%-34s %-34s %-10s %-8s %-8s %s\n" "TEST" "FUNCTION" "MIN_SUITE" "LAYER" "TIMEOUT" "TOOLS"
  printf '%s\n' "---------------------------------------------------------------------------------------------------------------"
  local i
  for i in "${!TEST_NAMES[@]}"; do
    printf "%-34s %-34s %-10s %-8s %-8s %s\n" \
      "${TEST_NAMES[$i]}" "${TEST_FUNCS[$i]}" "${TEST_MIN_SUITES[$i]}" "${TEST_LAYERS[$i]}" "${TEST_TIMEOUTS[$i]}" "${TEST_TOOLS[$i]}"
  done
}

if [ "$LIST_ONLY" = true ]; then
  list_tests
  exit 0
fi

aws_cmd() {
  local args=("$@")
  [ -n "$AWS_PROFILE_OPT" ] && args+=(--profile "$AWS_PROFILE_OPT")
  [ -n "$AWS_REGION_OPT" ] && args+=(--region "$AWS_REGION_OPT")
  aws "${args[@]}"
}

require_tools() {
  local cmd
  for cmd in kubectl aws envsubst; do
    command -v "$cmd" >/dev/null || { log_fail "required tool not found: $cmd"; exit 1; }
  done
}

ensure_context() {
  local ctx cluster
  ctx=$(kubectl config current-context 2>/dev/null || true)
  cluster=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null || true)
  # EKS context cluster names are ARNs (arn:aws:eks:...:cluster/<name>); take the last path segment
  # and compare it exactly so "prod" cannot match "prod-legacy". For a non-ARN name (no slash) the
  # strip is a no-op — a plain equality check, since this namespace-deleting harness must be certain
  # of its target cluster.
  if [ "${cluster##*/}" != "$CLUSTER_NAME" ]; then
    log_fail "current kubectl context ($ctx) does not target $CLUSTER_NAME (got: $cluster)"
    exit 1
  fi
  log_info "kubectl context: $ctx (cluster: $CLUSTER_NAME)"
}

selected_layer_present() {
  local wanted="$1" i
  for i in "${!TEST_NAMES[@]}"; do
    if [ "${TEST_LAYERS[$i]}" = "$wanted" ] && test_selected "${TEST_MIN_SUITES[$i]}" "${TEST_LAYERS[$i]}"; then
      return 0
    fi
  done
  return 1
}

# The harness only ever deletes a namespace it owns (one created with the managed-by label below),
# so pointing --namespace at a pre-existing workload namespace can never tear it down.
namespace_is_ours() {
  [ "$(kubectl get namespace "$NAMESPACE" \
        -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null)" \
    = eks-regression-tests ]
}

delete_test_pvs() {
  local name owner
  for name in $(test_pv_names); do
    owner="$(kubectl get pv "$name" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)"
    [ "$owner" = eks-regression-tests ] || continue
    kubectl delete pv "$name" --wait=false 2>/dev/null || true
  done
}

setup_namespace() {
  if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    if ! namespace_is_ours; then
      log_fail "namespace $NAMESPACE already exists and is not owned by the test harness"
      log_fail "  (missing label app.kubernetes.io/managed-by=eks-regression-tests) — refusing to"
      log_fail "  delete it. Pass a fresh --namespace."
      exit 1
    fi
    log_info "namespace $NAMESPACE already exists (test-owned) — recreating"
    kubectl delete namespace "$NAMESPACE" --wait=true --timeout=90s 2>/dev/null || true
    delete_test_pvs
    local deadline=$(($(date +%s) + 60))
    while kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; do
      if [ "$(date +%s)" -ge "$deadline" ]; then
        log_fail "namespace $NAMESPACE stuck Terminating past 60s; not recreating over it"
        exit 1
      fi
      sleep 3
    done
  fi
  # shellcheck disable=SC2016
  envsubst '$NAMESPACE' < "$SCRIPT_DIR/manifests/namespace.yaml" | kubectl apply -f -
}

teardown_namespace() {
  if [ "$KEEP_NS" = true ]; then
    log_info "keeping namespace $NAMESPACE for inspection (--keep-ns)"
    return
  fi
  # Only tear down what we own: if setup aborted on a foreign namespace, leave everything untouched.
  if namespace_is_ours; then
    log_info "cleaning up namespace $NAMESPACE"
    kubectl delete namespace "$NAMESPACE" --wait=false 2>/dev/null || true
    delete_test_pvs
  fi
}

apply_manifest() {
  envsubst "$ENVSUBST_VARS" < "$SCRIPT_DIR/manifests/$1" | kubectl apply -f -
}

run_registry() {
  local i name func min_suite layer timeout tools last_layer rc gpu_launch_failed=false
  for i in "${!TEST_NAMES[@]}"; do
    name="${TEST_NAMES[$i]}"
    func="${TEST_FUNCS[$i]}"
    min_suite="${TEST_MIN_SUITES[$i]}"
    layer="${TEST_LAYERS[$i]}"
    timeout="${TEST_TIMEOUTS[$i]}"
    tools="${TEST_TOOLS[$i]}"

    test_selected "$min_suite" "$layer" || continue
    if [ "$layer" = gpu ] && [ "$gpu_launch_failed" = true ]; then
      skip_test "$name" "gpu node did not launch"
      continue
    fi
    # shellcheck disable=SC2086
    if [ -n "$tools" ] && ! tools_available $tools; then
      skip_test "$name" "missing optional tool: $tools"
      continue
    fi
    if [ "${last_layer:-}" != "$layer" ]; then
      log_info "--- $layer tests ---"
      last_layer="$layer"
    fi
    # run_test toggles the shell's errexit state internally, so guard the call with `|| rc=$?`
    # (immune to set -e regardless of that state) instead of a set +e/set -e fence, which a
    # non-zero return would otherwise escape and abort the whole run.
    rc=0
    run_test "$name" "$timeout" "$func" || rc=$?
    if [ "$name" = gpu-node-launch ] && [ "$rc" -ne 0 ]; then
      gpu_launch_failed=true
    fi
  done
}

main() {
  require_tools
  resolve_cluster_name
  [ -n "$CLUSTER_NAME" ] || { echo "Error: could not determine cluster name; pass --cluster-name." >&2; exit 1; }
  resolve_region
  [ -n "$AWS_REGION_OPT" ] || { echo "Error: could not determine region; pass --region or set AWS_DEFAULT_REGION." >&2; exit 1; }
  # Validate the kubectl context BEFORE any cluster reads (e.g. NVIDIA pool derivation), so a pool
  # is never derived from the wrong cluster.
  ensure_context
  if selected_layer_present gpu; then
    resolve_gpu_nodepool
    [ -n "$GPU_NODEPOOL" ] || { echo "Error: gpu layer selected but no NVIDIA accelerator pool was derived; pass --gpu-nodepool." >&2; exit 1; }
  fi
  export NAMESPACE GPU_COUNT GPU_NODEPOOL

  trap teardown_namespace EXIT

  log_info "=== EKS Infra Regression Tests ==="
  log_info "cluster: $CLUSTER_NAME, namespace: $NAMESPACE, suite: $SUITE, gpu-count: $GPU_COUNT"

  if selected_layer_present live-mut || selected_layer_present gpu || selected_layer_present neuron; then
    setup_namespace
  fi

  run_registry
  print_summary
  [ "$FAIL_COUNT" -eq 0 ]
}

main

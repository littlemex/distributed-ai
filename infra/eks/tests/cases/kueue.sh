#!/usr/bin/env bash
# Advanced03 end to end: run the SAME workshop scenario (kueue-reference template + charts/experiments
# trainjobTrain.queueName) the book documents — deploy (submit 3 TrainJobs under a 1-job quota,
# asserting the quota is never exceeded) -> verify (each job's own output, 0 pending workloads) ->
# teardown. This is the live counterpart to the static chart-contract checks on trainjobTrain.

# The TrainJobs mount shared-claim (fixed by the shared ClusterTrainingRuntime), which the harness's
# own namespace does not have; give it one, test-owned so delete_test_pvs removes its PV.
ensure_shared_claim() {
  local rc=0 deadline
  resolve_storage_vars || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  read -r _ _ SHARED_TEST_PV_NAME <<< "$(test_pv_names)"
  assert_test_pv_free "$SHARED_TEST_PV_NAME" || return 1
  export SHARED_TEST_PV_NAME
  apply_manifest storage-test-shared-claim.yaml
  deadline=$(($(date +%s) + 30))
  until [ "$(kubectl get pvc shared-claim -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)" = Bound ]; do
    [ "$(date +%s)" -ge "$deadline" ] && { printf 'shared-claim did not bind within 30s\n' >&2; return 1; }
    sleep 3
  done
}

test_kueue_job_scheduling() {
  local sc="$SCRIPT_DIR/scenarios/advanced03-kueue-job-scheduling" image
  resolve_gpu_nodepool
  [ -n "$GPU_NODEPOOL" ] || return 2   # SKIP: no NVIDIA pool derived
  image="$(tf_out ddp_sample_ecr_url)"
  [ -n "$image" ] || return 2          # SKIP: ddp-sample image not built on this cluster (Basic02)
  image="${image}:v1"
  local rc=0 run_id
  ensure_shared_claim || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  run_id="$(date +%s)"
  # shellcheck disable=SC2064
  trap "NAMESPACE='$NAMESPACE' NODE_ROLE='$GPU_NODEPOOL' bash '$sc/teardown.sh' >/dev/null 2>&1 || true" EXIT
  # shellcheck disable=SC2064
  trap "NAMESPACE='$NAMESPACE' NODE_ROLE='$GPU_NODEPOOL' bash '$sc/teardown.sh' >/dev/null 2>&1 || true; exit 143" TERM
  NAMESPACE="$NAMESPACE" NODE_ROLE="$GPU_NODEPOOL" IMAGE="$image" RUN_ID="$run_id" bash "$sc/deploy.sh" || return 1
  NAMESPACE="$NAMESPACE" NODE_ROLE="$GPU_NODEPOOL" RUN_ID="$run_id" bash "$sc/verify.sh" || return 1
}

#!/usr/bin/env bash
# Trainium serving test (vLLM Neuron plugin). This runs the SAME workshop scenario that Basic09
# documents — the scripts under tests/scenarios/basic09-neuron-vllm/ are the single source of
# truth, so a regression in the chart or the workshop commands is caught here. Standalone 'neuron'
# suite: it needs a Trainium node (a region-specific Capacity Block) and is never part of
# baseline/coverage/full — run it with `./run-tests.sh --suite neuron`.

# True when some node advertises the Neuron device resource (a joined trn/inf node). Used to SKIP
# (rc=2) rather than FAIL when the cluster/region has no Trainium capacity.
neuron_node_present() {
  kubectl get nodes \
    -o jsonpath='{range .items[*]}{.status.capacity.aws\.amazon\.com/neuron}{"\n"}{end}' 2>/dev/null \
    | grep -qE '^[1-9]'
}

test_neuron_vllm_qwen3vl() {
  local sc="$SCRIPT_DIR/scenarios/basic09-neuron-vllm"
  neuron_node_present || return 2   # SKIP: no Trainium node in this cluster/region

  # Run the workshop scenario: deploy (chart) -> verify (API) -> teardown. Tear down on both exit
  # paths of run_test's subshell: EXIT (errexit failure) and TERM (watchdog SIGTERM on timeout).
  # The scripts take NAMESPACE from the environment; the harness namespace is test-owned.
  # shellcheck disable=SC2064
  trap "NAMESPACE='$NAMESPACE' bash '$sc/teardown.sh' >/dev/null 2>&1 || true" EXIT
  # shellcheck disable=SC2064
  trap "NAMESPACE='$NAMESPACE' bash '$sc/teardown.sh' >/dev/null 2>&1 || true; exit 143" TERM

  NAMESPACE="$NAMESPACE" bash "$sc/deploy.sh" || return 1
  NAMESPACE="$NAMESPACE" bash "$sc/verify.sh" || return 1
}

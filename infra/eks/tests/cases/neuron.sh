#!/usr/bin/env bash
# Trainium serving test (vLLM Neuron plugin). This runs the SAME workshop scenario that Basic09
# documents — the scripts under tests/scenarios/basic09-neuron-vllm/ are the single source of
# truth, so a regression in the chart or the workshop commands is caught here. Standalone 'neuron'
# suite: it needs a Trainium node (a region-specific Capacity Block) and is never part of
# baseline/coverage/full — run it with `./run-tests.sh --suite neuron`.

# True when some node advertises the Neuron device resource (a joined trn/inf node). This suite is
# opt-in (`--suite neuron` only) and FAILs — does not SKIP — when it's false; see the comment in
# test_neuron_vllm_qwen3vl.
neuron_node_present() {
  kubectl get nodes \
    -o jsonpath='{range .items[*]}{.status.capacity.aws\.amazon\.com/neuron}{"\n"}{end}' 2>/dev/null \
    | grep -qE '^[1-9]'
}

# Best-effort diagnostics on deploy/verify failure. Trainium capacity is rare and slow to
# reacquire (the NEFF compile alone can take 10+ minutes on first run); teardown discards the pod
# immediately after, so without this a failure leaves nothing to debug from.
_neuron_dump_diagnostics() {
  local ns="$1" pod
  pod="$(kubectl get pod -n "$ns" -l app=neuron-vllm -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  [ -n "$pod" ] || { log_info "diagnostics: no neuron-vllm pod found in ns=$ns"; return 0; }
  log_info "diagnostics: describe pod/$pod"
  kubectl describe pod "$pod" -n "$ns" 2>&1 | tail -60
  log_info "diagnostics: logs (current container, last 150 lines)"
  kubectl logs "$pod" -n "$ns" --tail=150 2>&1
  log_info "diagnostics: logs (previous container, if any, last 150 lines)"
  kubectl logs "$pod" -n "$ns" --previous --tail=150 2>/dev/null || log_info "  (no previous container log)"
}

test_neuron_vllm_qwen3vl() {
  local sc="$SCRIPT_DIR/scenarios/basic09-neuron-vllm"
  # `--suite neuron` is explicit and opt-in: running it asserts you intend to validate Trainium
  # serving. If the prerequisite (a Trainium node advertising aws.amazon.com/neuron) is absent,
  # fail with an actionable message rather than skipping — a silent skip would report "nothing
  # wrong" when in fact nothing was validated.
  if ! neuron_node_present; then
    log_fail "no Trainium node present (no node advertises aws.amazon.com/neuron)."
    log_fail "  This suite validates Basic09 serving on a Trainium node; bring up a Capacity-Block"
    log_fail "  trn2 nodegroup (see Basic05/Basic09) before running --suite neuron."
    return 1
  fi

  # Run the workshop scenario: deploy (chart) -> verify (API) -> teardown. Tear down on both exit
  # paths of run_test's subshell: EXIT (errexit failure) and TERM (watchdog SIGTERM on timeout).
  # The scripts take NAMESPACE from the environment; the harness namespace is test-owned.
  # shellcheck disable=SC2064
  trap "NAMESPACE='$NAMESPACE' bash '$sc/teardown.sh' >/dev/null 2>&1 || true" EXIT
  # shellcheck disable=SC2064
  trap "NAMESPACE='$NAMESPACE' bash '$sc/teardown.sh' >/dev/null 2>&1 || true; exit 143" TERM

  NAMESPACE="$NAMESPACE" bash "$sc/deploy.sh" || { _neuron_dump_diagnostics "$NAMESPACE"; return 1; }
  NAMESPACE="$NAMESPACE" bash "$sc/verify.sh" || { _neuron_dump_diagnostics "$NAMESPACE"; return 1; }
}

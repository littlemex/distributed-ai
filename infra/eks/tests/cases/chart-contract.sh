#!/usr/bin/env bash
# Static chart-contract checks (P0). These render the workshop serving workloads with `helm
# template` — NO cluster — and assert the structural contract the workshop and the live scenarios
# depend on. This is what catches "someone broke gpu-serving-vllm.yaml / neuron-serving-vllm-plugin.yaml"
# on every PR, for free, regardless of whether GPU/Trainium capacity is available.

_cc_chart() { printf '%s' "$SCRIPT_DIR/../charts/experiments"; }

# True if the first non-comment, non-blank line strictly after a top-level 'limits:' key contains
# <needle> at exactly (limits-indent + 2) spaces — i.e. <needle> is really the first key inside the
# limits: mapping, not merely present somewhere in the text. A plain `grep -q <needle>` would still
# pass if the resources block's indentation got shifted (e.g. the accel line de-indented out of the
# mapping): the string survives, the manifest no longer parses as the resources block we intend.
# This has no cluster/schema-validation dependency (avoids needing kubectl/PyYAML against a live
# API server, which chart-contract deliberately runs without).
_cc_assert_nested_under_limits() {
  local render="$1" needle="$2"
  printf '%s\n' "$render" | awk -v needle="$needle" '
    /^ *limits:[ \t]*$/ {
      line = $0
      gsub(/[^ ].*/, "", line)
      want = length(line) + 2
      armed = 1
      next
    }
    armed && /^[ \t]*(#|$)/ { next }
    armed {
      armed = 0
      line = $0
      gsub(/[^ ].*/, "", line)
      n = length(line)
      if (n == want && index($0, needle) == n + 1) { found = 1 }
      exit
    }
    END { exit !found }
  '
}

# Assert a rendered workload: non-empty, a Deployment + Service, no unresolved template values, the
# expected accelerator resource request nested where it belongs, and a Service port.
# Args: <render> <accel-resource>
_cc_assert_serving() {
  local render="$1" accel="$2"
  printf '%s\n' "$render" | grep -q '^kind: Deployment$' || { echo "no Deployment"; return 1; }
  printf '%s\n' "$render" | grep -q '^kind: Service$' || { echo "no Service"; return 1; }
  if printf '%s\n' "$render" | grep -q '<no value>'; then echo "unresolved template (<no value>)"; return 1; fi
  _cc_assert_nested_under_limits "$render" "$accel" || { echo "accelerator request missing/misplaced under resources.limits: $accel"; return 1; }
  printf '%s\n' "$render" | grep -qE '^\s+- \{ name: http, port: [0-9]+' || { echo "no Service http port"; return 1; }
}

# gpuServingVllm (Basic07): renders nothing by default; with nodeRole it is a GPU vLLM Deployment.
test_static_gpu_serving_contract() {
  local chart render
  chart="$(_cc_chart)"
  if helm template cc "$chart" --show-only templates/gpu-serving-vllm.yaml >/dev/null 2>&1; then
    echo "gpuServingVllm rendered while disabled"; return 1
  fi
  render="$(helm template cc "$chart" --show-only templates/gpu-serving-vllm.yaml \
    --set gpuServingVllm.enabled=true --set gpuServingVllm.nodeRole=test-pool)" || return 1
  _cc_assert_serving "$render" 'nvidia.com/gpu:' || return 1
  # nodeRole must be wired into the nodeSelector.
  printf '%s\n' "$render" | grep -q '^        node-role: test-pool$' || { echo "nodeRole not wired"; return 1; }
}

# neuronVllmPlugin (Basic09): renders nothing by default; with enabled it is a Neuron vLLM plugin
# Deployment that requests the whole device and uses the Recreate strategy.
test_static_neuron_plugin_contract() {
  local chart render
  chart="$(_cc_chart)"
  if helm template cc "$chart" --show-only templates/neuron-serving-vllm-plugin.yaml >/dev/null 2>&1; then
    echo "neuronVllmPlugin rendered while disabled"; return 1
  fi
  render="$(helm template cc "$chart" --show-only templates/neuron-serving-vllm-plugin.yaml \
    --set neuronVllmPlugin.enabled=true)" || return 1
  # Device request, NOT neuroncore (the whole point — a neuroncore request breaks TP multiproc).
  _cc_assert_serving "$render" 'aws.amazon.com/neuron:' || return 1
  # Reject a neuroncore request (breaks TP multiproc). Strip YAML comments first: the template has
  # an explanatory "NOT aws.amazon.com/neuroncore" comment that must not trip this check.
  if printf '%s\n' "$render" | grep -v '^[[:space:]]*#' | grep -q 'aws.amazon.com/neuroncore'; then
    echo "requests neuroncore (must be whole-device aws.amazon.com/neuron)"; return 1
  fi
  printf '%s\n' "$render" | grep -q '^    type: Recreate$' || { echo "not Recreate strategy"; return 1; }
  printf '%s\n' "$render" | grep -q '^  progressDeadlineSeconds:' || { echo "no progressDeadlineSeconds"; return 1; }
  # The verify scenario hits /health and /v1/*; the container must expose the http port it serves on.
  printf '%s\n' "$render" | grep -qE 'containerPort: [0-9]+' || { echo "no containerPort"; return 1; }
}

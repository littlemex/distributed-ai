#!/usr/bin/env bash
# Static chart-contract checks (P0). These render the workshop serving workloads with `helm
# template` — NO cluster — and assert the structural contract the workshop and the live scenarios
# depend on. This is what catches "someone broke gpu-serving-vllm.yaml / neuron-serving-vllm-plugin.yaml"
# on every PR, for free, regardless of whether GPU/Trainium capacity is available.

_cc_chart() { printf '%s' "$SCRIPT_DIR/../charts/experiments"; }

# Vendor the chart's subchart dependencies (image-builder-lib) so `helm template` can render. The
# vendored charts/ dir and Chart.lock are gitignored, so on a fresh checkout (CI, a reviewer's first
# run) they are absent and every render below fails with a "dependency missing" error. Run at most
# once per process (guarded): `helm dependency build` rewrites charts/*.tgz (and Chart.lock), so
# calling it concurrently would race on those files. `update` is a fallback for the rare Chart.lock
# / Chart.yaml digest mismatch. The current dependency is a local path (file://), so this needs no
# network — a future remote dependency would change that. A vendoring failure is fatal and its
# output surfaced: swallowing it would resurface downstream as a confusing render error with no
# vendoring context (same reasoning as scenarios/*/deploy.sh). Callers must use `|| return 1`.
_cc_ensure_deps() {
  [ -n "${_CC_DEPS_DONE:-}" ] && return 0
  local chart out; chart="$(_cc_chart)"
  if ! out="$(helm dependency build "$chart" 2>&1)"; then
    out="$(helm dependency update "$chart" 2>&1)" || { echo "chart dependency vendoring failed: $out"; return 1; }
  fi
  _CC_DEPS_DONE=1
}

# Render a single template from the chart with the given --set flags, failing the test with the
# helm error if the render fails. Ensures deps are vendored first. Args: <template-file> [--set ...]
_cc_render() {
  local tmpl="$1"; shift
  _cc_ensure_deps || return 1
  helm template cc "$(_cc_chart)" --show-only "templates/$tmpl" "$@"
}

# Assert a component renders NOTHING when disabled. `helm template --show-only` on a template that
# evaluated to empty exits non-zero with "could not find template ... in chart"; that specific error
# is the success signal here. Any OTHER failure (a missing dependency, a template execution error
# from a default-values regression) must fail the test loudly rather than be misread as "correctly
# disabled" — otherwise a change that breaks `helm install` at defaults would slip through this P0.
# Args: <template-file>
_cc_assert_absent_when_disabled() {
  local tmpl="$1" err
  _cc_ensure_deps || return 1
  if err="$(helm template cc "$(_cc_chart)" --show-only "templates/$tmpl" 2>&1)"; then
    echo "$tmpl rendered while disabled"; return 1
  fi
  printf '%s' "$err" | grep -q 'could not find template' \
    || { echo "unexpected failure rendering disabled $tmpl: $err"; return 1; }
}

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

# NCCL_SOCKET_IFNAME must come from ONE place for all three NCCL workloads. It used to be a literal
# repeated in each template, which is how ncclProbe and ncclSshd silently stopped following the
# value ncclTrainjob read from values.yaml. The failure that regression produces is nasty: the
# workload the reader measures with rendezvouses while the one they sanity-check with hangs, and
# nothing in either pod's output points at the chart. So assert the wiring, not just the default.
test_static_nccl_socket_ifname_single_source() {
  local pool=test-pool tj probe sshd overridden
  tj="$(_cc_render nccl-trainjob.yaml --set ncclTrainjob.enabled=true \
    --set ncclTrainjob.nodeRole=$pool --set ncclTrainjob.gpuCount=8 --set ncclTrainjob.efaCount=1 \
    --set ncclTrainjob.image=example:v1 --set sharedStorage.existingClaimName=shared-claim)" || return 1
  probe="$(_cc_render nccl-probe.yaml --set ncclProbe.enabled=true --set ncclProbe.nodeRole=$pool)" || return 1
  sshd="$(_cc_render nccl-sshd.yaml --set ncclSshd.enabled=true --set ncclSshd.nodeRole=$pool \
    --set sharedStorage.existingClaimName=shared-claim)" || return 1
  local want='"^lo,docker,veth"'
  local w
  for w in "trainjob:$tj" "probe:$probe" "sshd:$sshd"; do
    printf '%s\n' "${w#*:}" | grep -q "NCCL_SOCKET_IFNAME.*value: $want" \
      || { echo "${w%%:*} does not carry the chart-wide NCCL_SOCKET_IFNAME default ($want)"; return 1; }
  done
  # Moving the chart-wide value must move every workload, not just the one that reads its own key.
  # (helm --set splits on "," so the comma in the pattern is escaped.)
  local i
  for i in nccl-trainjob:ncclTrainjob nccl-probe:ncclProbe nccl-sshd:ncclSshd; do
    local tmpl="${i%%:*}" key="${i#*:}"
    overridden="$(_cc_render "$tmpl.yaml" --set "$key.enabled=true" --set "$key.nodeRole=$pool" \
      --set "$key.gpuCount=8" --set "$key.efaCount=1" --set "$key.image=example:v1" \
      --set sharedStorage.existingClaimName=shared-claim \
      --set 'ncclSocketIfname=^lo\,probe-only-check')" || return 1
    printf '%s\n' "$overridden" | grep -q 'NCCL_SOCKET_IFNAME.*value: "\^lo,probe-only-check"' \
      || { echo "$tmpl ignores the chart-wide ncclSocketIfname override (literal left in template?)"; return 1; }
  done
}

# gpuServingVllm (Basic07): renders nothing by default; with nodeRole it is a GPU vLLM Deployment.
test_static_gpu_serving_contract() {
  local render
  _cc_assert_absent_when_disabled gpu-serving-vllm.yaml || return 1
  render="$(_cc_render gpu-serving-vllm.yaml \
    --set gpuServingVllm.enabled=true --set gpuServingVllm.nodeRole=test-pool)" || return 1
  _cc_assert_serving "$render" 'nvidia.com/gpu:' || return 1
  # nodeRole must be wired into the nodeSelector.
  printf '%s\n' "$render" | grep -q '^        node-role: test-pool$' || { echo "nodeRole not wired"; return 1; }
}

# extraArgs: engine flags the chart does not know about, appended after the ones it renders. All three serving
# templates take them through one helper, so all three are checked here.
#
# Four properties, each with its own failure mode:
#
#   1. a values file that does NOT set them renders byte-identically to one that sets an empty list, which is the
#      property that makes this key safe to add to a chart people already use. Compared as whole manifests rather than
#      as an arg list: the first version of the helper wrote a blank line of indentation when the list was empty, which
#      no arg-level comparison sees;
#   2. a supplied flag arrives, in order, AFTER the chart's own -- the position the values comment promises;
#   3. a bare string is refused, because `range` over a string iterates characters and the container would start with
#      one argument per letter;
#   4. an empty element is refused, because it renders `- ""` and the engine dies at startup on an argparse error that
#      names nothing an operator can find.
#
# 3 and 4 are the ones worth the lines: both render SUCCESSFULLY and fail somewhere else.
_cc_args_of() {  # _cc_args_of <render>   -> one container arg per line, in order, unquoted
  printf '%s\n' "$1" | awk '
    /^          args:$/ { inargs = 1; next }
    inargs && /^          [^ ]/ { inargs = 0 }
    inargs && /^            - / { sub(/^            - /, ""); gsub(/^"|"$/, ""); print }
  '
}

test_static_gpu_serving_extra_args() {
  local tmpl=gpu-serving-vllm.yaml key=gpuServingVllm
  local unset_render empty_render set_render out want
  local base=(--set "$key.enabled=true" --set "$key.nodeRole=test-pool")

  # 1. Unset and empty must be the same manifest, byte for byte.
  unset_render="$(_cc_render "$tmpl" "${base[@]}")" || return 1
  empty_render="$(_cc_render "$tmpl" "${base[@]}" --set-json "$key.extraArgs=[]")" || return 1
  [ "$unset_render" = "$empty_render" ] || {
    echo "an empty extraArgs changes the manifest:"; diff <(printf '%s\n' "$unset_render") <(printf '%s\n' "$empty_render") || true
    return 1; }

  # 2. Supplied flags land after the chart's own, in the order given.
  want="$(_cc_args_of "$unset_render")"
  set_render="$(_cc_render "$tmpl" "${base[@]}" \
    --set-json "$key.extraArgs=[\"--enable-auto-tool-choice\",\"--tool-call-parser=hermes\"]")" || return 1
  [ "$(_cc_args_of "$set_render")" = "$want
--enable-auto-tool-choice
--tool-call-parser=hermes" ] || {
    echo "extraArgs did not render as the chart's own flags followed by the supplied ones:"
    _cc_args_of "$set_render"; return 1; }
  # And no blank line between them. The extractor above skips blank lines, so without this a helper that emits one
  # (dropping `trim` at the call site does exactly that) passes every other assertion here.
  if printf '%s\n' "$set_render" | awk '
      /^          args:$/ { inargs = 1; next }
      inargs && /^          [^ ]/ { inargs = 0 }
      inargs && /^[[:space:]]*$/ { found = 1 }
      END { exit !found }'; then
    echo "the rendered args block contains a blank line"; printf '%s\n' "$set_render" | sed -n '/args:/,/env:/p'; return 1
  fi

  # 3. A bare string, and the refusal has to say how to pass a list -- forgetting the --set braces is the mistake.
  if out="$(_cc_render "$tmpl" "${base[@]}" --set "$key.extraArgs=--flag" 2>&1)"; then
    echo "a bare string was accepted for extraArgs"; return 1; fi
  case "$out" in *"must be a list of strings"*) ;; *) echo "refused a string without saying why: $out"; return 1 ;; esac
  case "$out" in *"--set"*) ;; *) echo "the refusal does not say how to pass a list: $out"; return 1 ;; esac

  # 4. An empty element.
  if out="$(_cc_render "$tmpl" "${base[@]}" --set-json "$key.extraArgs=[\"--flag\",\"\"]" 2>&1)"; then
    echo "an empty extraArgs element was accepted"; return 1; fi
  case "$out" in *"empty element"*) ;; *) echo "refused an empty element without saying why: $out"; return 1 ;; esac

  # 5. Repeating a flag the chart renders itself. The chart puts `port` into the Service and the readiness probe as well,
  #    so an override that reaches only the engine leaves the Pod NotReady with nothing in its log about why. Refused
  #    rather than documented, and checked for EVERY flag the default render contains rather than for one of them: a
  #    guard verified on a single member of a set silently permits removing the rest.
  local flag
  while read -r flag; do
    [ -n "$flag" ] || continue
    flag="${flag%%=*}"
    if out="$(_cc_render "$tmpl" "${base[@]}" --set-json "$key.extraArgs=[\"$flag=x\"]" 2>&1)"; then
      echo "extraArgs was allowed to repeat $flag, which the chart renders itself"; return 1; fi
    case "$out" in *"may not set $flag"*) ;; *) echo "refusing $flag did not name it: $out"; return 1 ;; esac
  done <<EOF
$(_cc_args_of "$unset_render")
EOF
}

# The same knob on the Neuron serving workloads. The 400 a request carrying tools gets is produced by the
# OpenAI-compatible server layer, which is the same code whichever accelerator is underneath, so a chart that opens the
# door on one and not the other hands an operator a contract that changes when they move between them.
test_static_neuron_serving_extra_args() {
  local tmpl key unset_render set_render want
  for pair in "neuron-serving-vllm.yaml neuronServingVllm" "neuron-serving-vllm-plugin.yaml neuronVllmPlugin"; do
    set -- $pair; tmpl="$1"; key="$2"
    unset_render="$(_cc_render "$tmpl" --set "$key.enabled=true")" || return 1
    [ "$unset_render" = "$(_cc_render "$tmpl" --set "$key.enabled=true" --set-json "$key.extraArgs=[]")" ] || {
      echo "$key: an empty extraArgs changes the manifest"; return 1; }
    want="$(_cc_args_of "$unset_render")"
    set_render="$(_cc_render "$tmpl" --set "$key.enabled=true" --set-json "$key.extraArgs=[\"--flag=1\"]")" || return 1
    [ "$(_cc_args_of "$set_render")" = "$want
--flag=1" ] || { echo "$key: extraArgs did not append after the chart's own flags"; _cc_args_of "$set_render"; return 1; }
    # And every flag this template renders itself is refused, for the same reason as on the GPU side.
    local flag out
    while read -r flag; do
      [ -n "$flag" ] || continue
      flag="${flag%%=*}"
      if out="$(_cc_render "$tmpl" --set "$key.enabled=true" --set-json "$key.extraArgs=[\"$flag=x\"]" 2>&1)"; then
        echo "$key: extraArgs was allowed to repeat $flag"; return 1; fi
      case "$out" in *"may not set $flag"*) ;; *) echo "$key: refusing $flag did not name it: $out"; return 1 ;; esac
    done <<EOF
$(_cc_args_of "$unset_render")
EOF
  done
}

# neuronVllmPlugin (Basic09): renders nothing by default; with enabled it is a Neuron vLLM plugin
# Deployment that requests the whole device and uses the Recreate strategy.
test_static_neuron_plugin_contract() {
  local render
  _cc_assert_absent_when_disabled neuron-serving-vllm-plugin.yaml || return 1
  render="$(_cc_render neuron-serving-vllm-plugin.yaml \
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

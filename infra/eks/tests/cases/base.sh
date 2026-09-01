#!/usr/bin/env bash
# Cluster smoke test cases. Files under cases/ group functions by area; each test's layer and suite
# are declared in registry.sh (the single source).

# `producer | grep -q ...` is a race under `set -o pipefail`: grep exits at its first match and closes
# the pipe, and if the producer has not finished writing it dies of SIGPIPE, which pipefail turns into
# exit 141 for the whole pipeline. Measured: this test passed and then reported `exit 141` on the next
# run against an unchanged cluster. Reading the output into a variable first removes the pipe, so the
# result depends on the cluster rather than on who finished first.
test_control_plane() {
  local status health
  status="$(aws_cmd eks describe-cluster --name "$CLUSTER_NAME" --query 'cluster.status' --output text)"
  [ "$status" = ACTIVE ] || { printf 'cluster status is %s\n' "$status" >&2; return 1; }
  # `|| true` here would make a request that failed indistinguishable from one that answered something
  # unhealthy, and /healthz answers exactly "ok" rather than containing it. 2>&1 into the same variable
  # would be its own trap: a deprecation warning on stderr would then read as an unhealthy answer.
  health="$(_kread kubectl get --raw /healthz)" || {
    printf 'the /healthz request failed: %s\n' "$health" >&2
    return 1
  }
  [ "$health" = ok ] || { printf '/healthz said "%s"\n' "$health" >&2; return 1; }
}

# `grep -qv True` accepted a line reading "FalseTrue", and being an early-exit pipeline it could report
# its producer's SIGPIPE instead of its own answer. Objects are listed as name|status so that "there are
# none" and "there is one whose status is empty" stay different answers, and awk reads all of its input
# and compares whole fields.
#
# Prints two numbers: how many objects were listed, and how many of them are not exactly Ready=True.
_ready_tally() {
  printf '%s\n' "$1" | awk -F'|' '
    NF { total++; if ($2 != "True") { bad++; names = names " " $1 "(" ($2 == "" ? "none" : $2) ")" } }
    END { printf "%d %d%s\n", total + 0, bad + 0, names }
  '
}

test_system_nodes() {
  local states tally total bad
  states="$(_kread kubectl get nodes -l 'eks.amazonaws.com/nodegroup' \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}')" || {
    printf 'reading the system nodes failed: %s\n' "$states" >&2
    return 1
  }
  tally="$(_ready_tally "$states")"
  total="${tally%% *}"
  bad="$(printf '%s' "$tally" | awk '{ print $2 }')"
  [ "$total" -ge 2 ] || { printf 'only %s system nodes\n' "$total" >&2; return 1; }
  [ "$bad" = 0 ] || { printf 'system nodes not Ready: %s\n' "${tally#* * }" >&2; return 1; }
}

test_karpenter() {
  local running
  running=$(kubectl get pods -n karpenter -l app.kubernetes.io/name=karpenter --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [ "$running" -ge 2 ] || return 1
  local states tally bad
  states="$(_kread kubectl get nodepool \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}')" || {
    printf 'reading the nodepools failed: %s\n' "$states" >&2
    return 1
  }
  tally="$(_ready_tally "$states")"
  bad="$(printf '%s' "$tally" | awk '{ print $2 }')"
  [ "$bad" = 0 ] || { printf 'nodepools not Ready: %s\n' "${tally#* * }" >&2; return 1; }
  # One list rather than two: counting with `--no-headers | wc -l` and matching with `grep -c True` let a
  # failed call read as zero objects, and two failed calls agreed with each other at zero.
  states="$(_kread kubectl get ec2nodeclass \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}')" || {
    printf 'reading the EC2NodeClasses failed: %s\n' "$states" >&2
    return 1
  }
  tally="$(_ready_tally "$states")"
  bad="$(printf '%s' "$tally" | awk '{ print $2 }')"
  [ "${tally%% *}" -gt 0 ] || { printf 'no EC2NodeClass exists\n' >&2; return 1; }
  [ "$bad" = 0 ] || { printf 'EC2NodeClasses not Ready: %s\n' "${tally#* * }" >&2; return 1; }
}

test_trainer() {
  # Kubeflow Trainer v2 control plane (replaces the old Training Operator v1). Installed by
  # trainer.tf as the "kubeflow-trainer" Helm release into kubeflow-system, with JobSet as a
  # bundled subchart. Assert BOTH the Trainer manager and the JobSet controller have a Running
  # pod — the manager alone would accept a TrainJob but the JobSet controller is what actually
  # creates the worker pods, so a missing JobSet controller is a silent "TrainJob never schedules".
  local manager running found
  # 2>&1 into the same variable would be a hole rather than a diagnosis: a warning on stderr would make
  # this non-empty with no Running pod behind it, so the count is over pod names only.
  manager="$(_kread kubectl get pods -n kubeflow-system -l app.kubernetes.io/instance=kubeflow-trainer \
    --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')" || {
    printf 'reading the trainer pods failed: %s\n' "$manager" >&2
    return 1
  }
  found="$(printf '%s\n' "$manager" | awk 'NF { n++ } END { print n + 0 }')"
  [ "$found" != 0 ] || { printf 'no Running kubeflow-trainer pod\n' >&2; return 1; }
  # JobSet is a bundled subchart, so its instance label differs from the parent release; match on the pod
  # name (fullnameOverride: jobset) to stay robust across chart-label changes. Names are asked for
  # directly rather than parsed out of `--no-headers` columns, whose layout is not a contract.
  running="$(_kread kubectl get pods -n kubeflow-system --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')" || {
    printf 'reading the kubeflow-system pods failed: %s\n' "$running" >&2
    return 1
  }
  found="$(printf '%s\n' "$running" | awk '/^jobset-/ { n++ } END { print n + 0 }')"
  [ "$found" != 0 ] || { printf 'no Running jobset- pod in kubeflow-system\n' >&2; return 1; }
}

# A cluster with Karpenter in it is never quiet, and a DaemonSet's status says so. The moment a node
# joins, desiredNumberScheduled counts it, before its pod could possibly be Ready; while a node is being
# consolidated, a terminating pod is still counted. Comparing those two numbers in one snapshot therefore
# reports a broken driver whenever a node happens to be arriving or leaving, which is what made these
# checks flaky rather than informative.
#
# What replaces it keeps both halves of what the old comparison meant and drops only the part that was
# about timing:
#   - one of the DaemonSet's pods must sit on each node it wants, counted as distinct nodes among the
#     nodes that still exist. Counting distinct nodes rather than pods is what stops a second pod on one
#     node — an old one terminating while its replacement starts — from covering for a node with none.
#     Counting only nodes that still exist is what makes a draining node harmless: the node object goes
#     away and its terminating pod goes with it, while a pod evicted from a node that stayed is caught.
#   - every pod that sits on a Ready node must be Ready itself. A node whose kubelet has not reported in
#     cannot be expected to have a Ready pod, and counting it says nothing about the driver.
# A cluster that is genuinely mid-settle then gets a short deadline to converge, so a driver that is
# actually broken still fails — after the deadline, with the pods and their nodes named.
#
# What this deliberately does not assert: that every node is Ready. A node is not Ready for about a
# minute every single time Karpenter adds one, so failing on that would rebuild the flake this exists to
# remove. Node readiness is system-nodes' subject for the system nodegroup and the gpu layer's for the
# pools it launches; here a node that is not Ready is only reported as context when something else fails.
# The consequence, stated rather than hidden: a driver broken on a node that stays NotReady is not caught
# here.
#
# The state is read once per pass into files and judged in one awk pass over them. Two reasons: a list
# call per object cost 28 seconds, which left no room to retry inside the 60 the registry gives each test
# in this layer; and a shell loop that pipes into `grep -q` is the same early-exit pipeline whose SIGPIPE
# this commit fixes elsewhere.
#
# Fields are separated by "|", not by a tab. Tab is an IFS whitespace character, so `read` collapses runs
# of them and strips leading ones — a Pending pod with no nodeName, or a pod whose Ready condition has
# not been written yet, would silently shift every later field one column to the left. "|" cannot appear
# in a Kubernetes object name.

CSI_NODE_DAEMONSETS="ebs-csi-node efs-csi-node fsx-csi-node fsx-openzfs-csi-node"
CSI_CONTROLLERS="ebs-csi-controller efs-csi-controller fsx-csi-controller fsx-openzfs-csi-controller"
# GPU device plugin lives in gpu-operator; EFA, Neuron and gdrcopy plugins in kube-system.
DEVICE_PLUGINS_KUBE_SYSTEM="aws-efa-k8s-device-plugin neuron-device-plugin-daemonset neuron-device-plugin gdrcopy-device-plugin"
DEVICE_PLUGINS_GPU_OPERATOR="nvidia-device-plugin-daemonset"

# One list call whose failure can never be mistaken for an empty list, and whose warnings can never be
# mistaken for data. The redirection order matters and is easy to get backwards: `>"$out" 2>&1` points
# stderr at the file too, which both loses the diagnosis and lets a deprecation or throttling warning
# land in the data as an extra record. `2>&1 >"$out"` sends stderr to the capture and stdout to the file.
_kget() {
  local out="$1"; shift
  local what="$*" err rc=0
  err="$("$@" 2>&1 >"$out")" || rc=$?
  [ "$rc" = 0 ] || { printf 'reading the cluster failed (%s): %s\n' "$what" "$err"; return 1; }
  return 0
}

# The same, for a caller that wants the data rather than a file: prints it on stdout, and on failure
# prints the reason there instead and returns 1.
_kread() {
  local f rc=0
  f="$(mktemp)" || { printf 'mktemp failed\n'; return 1; }
  _kget "$f" "$@" || rc=$?
  [ "$rc" = 0 ] && cat "$f"
  rm -f "$f"
  return "$rc"
}

_read_nodes() {
  _kget "$1/nodes" kubectl get nodes \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}'
}

_read_ds() {
  _kget "$2/ds-$1" kubectl get daemonsets -n "$1" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.desiredNumberScheduled}{"|"}{.status.numberReady}{"\n"}{end}'
}

# Owners are read as the whole list of kind/name/controller triples rather than as element zero: the API
# does not promise which owner comes first, and only the one with controller=true owns the pod.
_read_pods() {
  _kget "$2/pods-$1" kubectl get pods -n "$1" \
    -o jsonpath='{range .items[*]}{range .metadata.ownerReferences[*]}{.kind}/{.name}/{.controller},{end}{"|"}{.spec.nodeName}{"|"}{.status.conditions[?(@.type=="Ready")].status}{"|"}{.status.phase}{"|"}{.metadata.name}{"\n"}{end}'
}

_read_deploys() {
  _kget "$2/deploys-$1" kubectl get deployments -n "$1" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.replicas}{"|"}{.status.availableReplicas}{"\n"}{end}'
}

# Only the two states nothing can be concluded from are failures here: no nodes at all, and no Ready node
# among them. A node whose Ready condition is missing entirely is reported, because that is a malformed
# object rather than a node in a known state.
_judge_nodes() {
  awk '
    BEGIN { FS = "|" }
    {
      total++
      if ($2 == "True") ready++
      else if ($2 == "") printf "node %s has no Ready condition\n", $1
    }
    END {
      if (total + 0 == 0) print "the cluster reports no nodes"
      else if (ready + 0 == 0) print "no node is Ready"
    }
  ' "$1/nodes"
}

# Context for a failure, not a failure itself: which nodes were not Ready while the rest was judged.
_note_nodes() {
  awk '
    BEGIN { FS = "|" }
    { if ($2 == "True") r++; else { n++; names = names " " $1 "(" ($2 == "" ? "none" : $2) ")" } }
    END { if (n + 0 > 0) printf "for context: %d node(s) Ready, %d not:%s\n", r + 0, n, names }
  ' "$1/nodes"
}

# mode=csi requires each named DaemonSet to exist and to want at least one node. mode=plugin treats a
# missing DaemonSet, or one whose desiredNumberScheduled is exactly 0, as "this cluster has no pool of
# that kind" — that is what the field is for, and it is a different question from "does it have a pod
# somewhere", which an earlier version of this asked and so passed a plugin whose pods were all Pending.
# A desired that is absent or not a number is a failure in both modes rather than a quiet zero.
#
# In plugin mode a pod that is still Pending is not held against the plugin. On a GPU node the operator
# validates the driver before the plugin can start, so its pod stays Pending for minutes after the node
# goes Ready, and no deadline this test can afford would cover that. A pod that is Running and not Ready
# is reported in both modes: that is the shape of a plugin that is actually broken. CSI node pods have no
# such dependency and start in seconds, so csi mode reports Pending too.
_judge_daemonsets() {
  local dir="$1" ns="$2" mode="$3" want="$4"
  awk -v want="$want" -v mode="$mode" -v nsname="$ns" \
      -v nf="$dir/nodes" -v dsf="$dir/ds-$ns" -v pf="$dir/pods-$ns" '
    BEGIN { FS = "|"; n = split(want, w, " "); for (i = 1; i <= n; i++) wanted[w[i]] = 1 }
    FILENAME == nf {
      exists[$1] = 1
      if ($2 == "True") node_ready[$1] = 1
      next
    }
    FILENAME == dsf {
      if ($1 in wanted) { present[$1] = 1; desired_raw[$1] = $2 }
      next
    }
    FILENAME == pf {
      for (d in wanted) {
        if (index($1, "DaemonSet/" d "/true,") == 0) continue
        if (!($2 in exists)) continue
        if (!((d SUBSEP $2) in seen_on)) { seen_on[d, $2] = 1; covered[d]++ }
        if (($2 in node_ready) && $3 != "True" && (mode == "csi" || $4 != "Pending"))
          bad[d] = bad[d] " " $5 "@" $2 "(phase=" ($4 == "" ? "none" : $4) ",ready=" ($3 == "" ? "none" : $3) ")"
      }
      next
    }
    END {
      # w[1..n] rather than "for (d in wanted)": awk does not order array traversal, and an unstable
      # order would make _settle compare its first and last diagnosis by luck.
      for (i = 1; i <= n; i++) {
        d = w[i]
        if (!(d in present)) {
          if (mode == "csi") printf "%s/%s: no such DaemonSet\n", nsname, d
          continue
        }
        if (desired_raw[d] !~ /^[0-9]+$/) {
          printf "%s/%s: desiredNumberScheduled is \"%s\", not a number\n", nsname, d, desired_raw[d]
          continue
        }
        desired = desired_raw[d] + 0
        if (desired == 0) {
          if (mode == "csi") printf "%s/%s: wants no node\n", nsname, d
          continue
        }
        if (covered[d] + 0 != desired)
          printf "%s/%s: has a pod on %d of the %d nodes it wants\n", nsname, d, covered[d] + 0, desired
        if (d in bad) printf "%s/%s: not Ready on Ready nodes:%s\n", nsname, d, bad[d]
      }
    }
  ' "$dir/nodes" "$dir/ds-$ns" "$dir/pods-$ns"
}

# Deployments are judged the same way and for the same reason: consolidation moves a controller pod and
# availableReplicas dips while the replacement starts. More available than asked for is a surge, not a
# fault, so only a shortfall counts.
_judge_deployments() {
  local dir="$1" ns="$2" want="$3"
  awk -v want="$want" -v nsname="$ns" '
    BEGIN { FS = "|"; n = split(want, w, " "); for (i = 1; i <= n; i++) wanted[w[i]] = 1 }
    { if ($1 in wanted) { seen[$1] = 1; spec[$1] = $2; avail[$1] = $3 + 0 } }
    END {
      for (i = 1; i <= n; i++) {
        d = w[i]
        if (!(d in seen)) { printf "%s/%s: no such deployment\n", nsname, d; continue }
        if (spec[d] !~ /^[0-9]+$/) { printf "%s/%s: replicas is \"%s\", not a number\n", nsname, d, spec[d]; continue }
        if (spec[d] + 0 == 0) { printf "%s/%s: scaled to zero\n", nsname, d; continue }
        if (avail[d] < spec[d] + 0)
          printf "%s/%s: %d of %d replicas available\n", nsname, d, avail[d], spec[d] + 0
      }
    }
  ' "$dir/deploys-$ns"
}

# Re-evaluate the predicate until it agrees or the deadline passes. The predicate is given a scratch
# directory as its argument and must only read the cluster: it is called again from scratch each time.
#
# 40 seconds sits under the 60 the registry gives each test in this layer; the timeout is per test, so two
# settling tests do not share it. A pass is not started unless the one just measured would fit before the
# deadline — an estimate from the previous pass, not a guarantee about the next one, which is why the
# margin exists at all. Both the first and the last diagnosis are reported when they differ, because a
# persistent fault reported only from the final pass can be masked by whatever transient the last read
# happened to catch. The body runs in a subshell so that the scratch directory is removed even when the
# harness kills the test on its own timeout.
_settle() {
  (
    local now deadline first="" last="" dir t0 t1 cost=0
    now="$(date +%s)" || return 1
    deadline=$((now + 40))
    dir="$(mktemp -d)" || return 1
    trap 'rm -rf "$dir"' EXIT HUP INT TERM
    while :; do
      t0="$(date +%s)" || return 1
      last="$("$@" "$dir")" && return 0
      t1="$(date +%s)" || return 1
      cost=$((t1 - t0))
      [ -n "$first" ] || first="$last"
      [ $((t1 + cost + 5)) -lt "$deadline" ] || break
      sleep 5
    done
    if [ "$first" = "$last" ]; then
      printf '%s\n' "$last" >&2
    else
      printf 'first pass:\n%s\nlast pass:\n%s\n' "$first" "$last" >&2
    fi
    return 1
  )
}

_csi_drivers_agree() {
  local dir="$1" problems=""
  _read_nodes "$dir" || return 1
  _read_ds kube-system "$dir" || return 1
  _read_pods kube-system "$dir" || return 1
  _read_deploys kube-system "$dir" || return 1
  problems="$(
    _judge_nodes "$dir"
    _judge_daemonsets "$dir" kube-system csi "$CSI_NODE_DAEMONSETS"
    _judge_deployments "$dir" kube-system "$CSI_CONTROLLERS"
  )"
  [ -z "$problems" ] || {
    printf '%s\n' "$problems"
    _note_nodes "$dir"
    return 1
  }
  return 0
}

test_csi_drivers() {
  _settle _csi_drivers_agree
}

# Accelerator device plugins: the NVIDIA GPU device plugin (GPU Operator), the EFA device
# plugin, the Neuron device plugin, and the opt-in gdrcopy device plugin. Each is only
# present/scheduled when the matching pool type exists (or, for gdrcopy, when
# var.gdrcopy_device_plugin_enabled = true), so this asserts "if the DaemonSet exists and
# wants pods, they are all Ready" and treats a missing or zero-desired DaemonSet as
# not-applicable (a cluster with no GPU/EFA/Neuron pool, or with gdrcopy left off, legitimately
# runs none of these). This closes the gap where a broken device plugin — the mechanism that
# advertises nvidia.com/gpu / vpc.amazonaws.com/efa / aws.amazon.com/neuron / gdrcopy/gdrdrv —
# went entirely untested even though EFA dynamic derivation and Neuron support are core features.
_device_plugins_agree() {
  local dir="$1" problems="" ns_out
  _read_nodes "$dir" || return 1
  _read_ds kube-system "$dir" || return 1
  _read_pods kube-system "$dir" || return 1
  # The gpu-operator namespace only exists where the GPU Operator is installed. Its absence is a fact
  # about the cluster; a call that failed is not, and `kubectl get namespace >/dev/null 2>&1` cannot tell
  # the two apart — a timeout or a denied request would silently skip every GPU plugin check.
  # --ignore-not-found makes absence an empty success instead of an error.
  ns_out="$(_kread kubectl get namespace gpu-operator --ignore-not-found -o name)" || {
    printf '%s\n' "$ns_out"
    return 1
  }
  if [ -n "$ns_out" ]; then
    _read_ds gpu-operator "$dir" || return 1
    _read_pods gpu-operator "$dir" || return 1
  else
    : >"$dir/ds-gpu-operator"
    : >"$dir/pods-gpu-operator"
  fi
  problems="$(
    _judge_nodes "$dir"
    _judge_daemonsets "$dir" kube-system plugin "$DEVICE_PLUGINS_KUBE_SYSTEM"
    _judge_daemonsets "$dir" gpu-operator plugin "$DEVICE_PLUGINS_GPU_OPERATOR"
  )"
  [ -z "$problems" ] || {
    printf '%s\n' "$problems"
    _note_nodes "$dir"
    return 1
  }
  return 0
}

test_device_plugins() {
  _settle _device_plugins_agree
}

ensure_storage_pvcs() {
  local deadline fsx_status openzfs_status rc=0
  resolve_storage_vars || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  apply_manifest storage-test-pv-fsx.yaml
  apply_manifest storage-test-pv-openzfs.yaml
  apply_manifest storage-test-pvc.yaml
  deadline=$(($(date +%s) + 30))
  while true; do
    fsx_status=$(kubectl get pvc fsx-claim-test -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    openzfs_status=$(kubectl get pvc openzfs-claim-test -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    [ "$fsx_status" = "Bound" ] && [ "$openzfs_status" = "Bound" ] && return 0
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 3
  done
}

test_storage_mount() {
  local rc=0
  ensure_storage_pvcs || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  apply_manifest storage-mount-pod.yaml
  wait_for_pod "$NAMESPACE" storage-mount-test Succeeded 120
}

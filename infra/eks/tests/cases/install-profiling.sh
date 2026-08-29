#!/usr/bin/env bash
# Tests for install-profiling.sh, against stubs. No cluster, no AWS.
#
# The installer orchestrates two Terraform states and seven phases, so what can be tested without a
# cluster is narrow: the contract it keeps with the shell that invoked it. That contract is worth a
# test because breaking it is invisible here and only shows up two commands later, in another tool.

# The installer must not write to the caller's kubeconfig at all. It reaches the cluster by naming a
# context on every kubectl and helm call, and aws eks update-kubeconfig both adds that context and
# makes it current, in whatever file KUBECONFIG points at. distai-env.sh points KUBECONFIG at one file
# per (cluster, namespace) and carries the chapter's namespace on its context, so writing there moved
# the caller onto a context with no namespace and the next client call resolved namespace "default".
# Run against stubs and stopped at the first reachability check, which is after the write would happen.
test_profiling_install_leaves_the_caller_kubeconfig_alone() {
  local script="$SCRIPT_DIR/../../scripts/install-profiling.sh"
  [ -x "$script" ] || return 2
  local real_kubectl dir fails=0
  real_kubectl="$(command -v kubectl)" || return 2
  dir="$(mktemp -d)"
  mkdir -p "$dir/bin"
  # The installer checks its whole toolchain before anything else, so a machine without terraform or
  # helm would fail here for the wrong reason. Stubs stand in for the ones this test never invokes.
  local tool
  for tool in terraform helm python3 curl; do
    command -v "$tool" >/dev/null && continue
    printf '#!/usr/bin/env bash\nexit 0\n' >"$dir/bin/$tool"
    chmod +x "$dir/bin/$tool"
  done
  # Only the two calls the installer makes before its first kubectl. update-kubeconfig reproduces what
  # the real one does: add a context, make it current, and honour --kubeconfig when it is given.
  cat >"$dir/bin/aws" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"describe-cluster"*) printf 'ACTIVE\n' ;;
  *"update-kubeconfig"*)
    alias_name="" target=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --alias) alias_name="$2"; shift 2 ;;
        --kubeconfig) target="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    [ -n "$target" ] && export KUBECONFIG="$target"
    "$REAL_KUBECTL" config set-cluster stub --server=https://stub.invalid >/dev/null
    "$REAL_KUBECTL" config set-context "$alias_name" --cluster=stub >/dev/null
    "$REAL_KUBECTL" config use-context "$alias_name" >/dev/null
    ;;
  *) ;;
esac
STUB
  # config subcommands are bookkeeping and go to the real binary; anything that would talk to a cluster
  # fails, which is where the installer stops.
  cat >"$dir/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "config" ] && exec "$REAL_KUBECTL" "$@"
printf 'stub kubectl: no cluster here (%s)\n' "$*" >&2
exit 1
STUB
  chmod +x "$dir/bin/aws" "$dir/bin/kubectl"
  local kc="$dir/kubeconfig.yaml"
  KUBECONFIG="$kc" "$real_kubectl" config set-cluster caller --server=https://caller.invalid >/dev/null
  KUBECONFIG="$kc" "$real_kubectl" config set-context caller-ctx --cluster=caller --namespace=team-a >/dev/null
  KUBECONFIG="$kc" "$real_kubectl" config use-context caller-ctx >/dev/null
  local before after
  before="$(cat "$kc")"
  env -u AWS_PROFILE KUBECONFIG="$kc" REAL_KUBECTL="$real_kubectl" PATH="$dir/bin:$PATH" \
    CLUSTER_NAME=stub-cluster AWS_REGION=us-east-2 PRODUCER_NAMESPACES=team-a \
    DATA_LAYER_NAME=stub-layer "$script" >"$dir/out.txt" 2>&1 && {
    printf 'FAIL the stubbed installer was expected to stop at its reachability check\n' >&2
    fails=$((fails + 1))
  }
  # Stopping for the wrong reason would pass every assertion below without testing anything.
  grep -q "cannot reach stub-cluster" "$dir/out.txt" || {
    printf 'FAIL the installer stopped before the write under test: %s\n' "$(tail -3 "$dir/out.txt")" >&2
    fails=$((fails + 1))
  }
  after="$(cat "$kc")"
  [ "$before" = "$after" ] || {
    printf "FAIL the caller's kubeconfig was modified:\n%s\n" \
      "$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") || true)" >&2
    fails=$((fails + 1))
  }
  rm -rf "$dir"
  [ "$fails" -eq 0 ] || return 1
}

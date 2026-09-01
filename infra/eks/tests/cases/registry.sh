#!/usr/bin/env bash
# Tests for the workshop registry and the chapter preamble it exists to serve (cd, CLUSTER_NAME,
# AWS_REGION, source).
#
# The registry holds only what Terraform cannot: where a cluster's state lives, which release it was
# applied with, and which data layers are attached. That makes these tests worth having — a registry
# that has drifted from reality is invisible until a chapter resolves the wrong cluster, and the
# four-line preamble is a contract (sourced, no exit, nothing on stdout) that a normal review would not catch
# breaking.

# The harness resolves the cluster and region for every test; the region lands in AWS_REGION_OPT
# because AWS_REGION is a CLI variable the harness must not clobber.
registry_region() { printf '%s' "${AWS_REGION_OPT:-${AWS_REGION:-}}"; }
registry_prefix() { printf '/distai/v1/clusters/%s' "$CLUSTER_NAME"; }

# aws_cmd, not aws: the harness carries the profile as a flag rather than in the environment, so a
# raw aws call here would run as whatever the ambient credentials are — or as none.
registry_value() {
  aws_cmd ssm get-parameter --name "$(registry_prefix)/$1" --region "$(registry_region)" \
    --query Parameter.Value --output text 2>/dev/null
}

# The registry agrees with the state it points at. Read-only, and the strongest of these checks: it is
# what says the preamble will resolve the same cluster the checkout manages.
test_registry_matches_state() {
  command -v terraform >/dev/null || return 2
  local bucket key registered
  bucket="$(registry_value state/bucket)" || return 2
  [ -n "$bucket" ] && [ "$bucket" != "None" ] || {
    printf 'cluster %s is not in the registry in %s\n' "$CLUSTER_NAME" "$(registry_region)" >&2
    return 1
  }
  key="$(registry_value state/key)"
  [ "$key" = "eks/${CLUSTER_NAME}/terraform.tfstate" ] || {
    printf 'registry state/key is %s, expected eks/%s/terraform.tfstate\n' "$key" "$CLUSTER_NAME" >&2
    return 1
  }
  registered="$(registry_value meta/account-id)"
  local caller
  caller="$(aws_cmd sts get-caller-identity --query Account --output text)"
  [ "$registered" = "$caller" ] || {
    printf 'registry meta/account-id is %s, caller is %s\n' "$registered" "$caller" >&2
    return 1
  }
  # The name in the state itself has to be the name the registry files it under.
  local in_state
  in_state="$(terraform -chdir="$SCRIPT_DIR/.." output -raw cluster_name 2>/dev/null || true)"
  [ -z "$in_state" ] || [ "$in_state" = "$CLUSTER_NAME" ] || {
    printf 'terraform output cluster_name is %s, registry path says %s\n' "$in_state" "$CLUSTER_NAME" >&2
    return 1
  }
}

# The default data layer, if there is one, is actually attached. A default pointing at a detached layer
# resolves to something that no longer exists, which is the failure the pointer was meant to prevent.
test_registry_default_data_layer_is_attached() {
  local default
  default="$(registry_value defaults/data-layer)"
  [ -n "$default" ] && [ "$default" != "None" ] || return 2
  aws_cmd ssm get-parameter --name "$(registry_prefix)/data-layers/${default}/manifest" \
    --region "$(registry_region)" >/dev/null 2>&1 || {
    printf 'default data layer %s is not attached\n' "$default" >&2
    return 1
  }
}

# The preamble's contract, in both shells a reader might use. zsh is the default on macOS and does not
# have BASH_SOURCE, which is exactly how this broke once: the helper reported success while writing no
# backend.hcl at all.
test_registry_preamble_contract() {
  local helper="$SCRIPT_DIR/../../scripts/distai-env.sh"
  [ -f "$helper" ] || return 2
  local shell out status
  for shell in bash zsh; do
    command -v "$shell" >/dev/null || continue
    # stdout must stay empty: a chapter may use the preamble inside a command substitution.
    out="$("$shell" -c "cd '$SCRIPT_DIR/../..' && CLUSTER_NAME='$CLUSTER_NAME' AWS_REGION='$(registry_region)' AWS_PROFILE='${AWS_PROFILE_OPT:-}' source scripts/distai-env.sh 2>/dev/null")"
    status=$?
    [ "$status" -eq 0 ] || { printf '%s: sourcing failed (%d)\n' "$shell" "$status" >&2; return 1; }
    [ -z "$out" ] || { printf '%s: wrote to stdout: %s\n' "$shell" "$out" >&2; return 1; }
    # And it must export what a chapter needs, in that same shell.
    out="$("$shell" -c "cd '$SCRIPT_DIR/../..' && CLUSTER_NAME='$CLUSTER_NAME' AWS_REGION='$(registry_region)' AWS_PROFILE='${AWS_PROFILE_OPT:-}' source scripts/distai-env.sh >/dev/null 2>&1; printf '%s' \"\$DISTAI_STATE_KEY\"")"
    [ "$out" = "eks/${CLUSTER_NAME}/terraform.tfstate" ] ||
      { printf '%s: DISTAI_STATE_KEY resolved to "%s"\n' "$shell" "$out" >&2; return 1; }
  done
}

# A missing cluster must fail, not fall back. The default that used to exist here ("mcp") is the
# accident this asserts is gone.
test_registry_unknown_cluster_fails() {
  local helper="$SCRIPT_DIR/../../scripts/distai-env.sh"
  [ -f "$helper" ] || return 2
  if bash -c "cd '$SCRIPT_DIR/../..' && CLUSTER_NAME=no-such-cluster-$$ AWS_REGION='$(registry_region)' AWS_PROFILE='${AWS_PROFILE_OPT:-}' source scripts/distai-env.sh >/dev/null 2>&1"; then
    printf 'sourcing succeeded for a cluster that is not registered\n' >&2
    return 1
  fi
}

# The kubectl side of the preamble, which is the part with side effects. Three of these assertions are
# bugs that were found in review rather than hypotheticals: a reader who already has `alias k=kubectl`
# in their rc file had this file's own `k() { ... }` alias-expanded while it was being read, which in
# bash silently redefined kubectl and in zsh was a parse error that abandoned the rest of the file; and
# the default kubeconfig must come out byte-identical, because repointing every terminal at whatever
# cluster was sourced last is not something a chapter preamble may do.
test_registry_preamble_configures_kubectl() {
  local helper="$SCRIPT_DIR/../../scripts/distai-env.sh"
  [ -f "$helper" ] || return 2
  command -v kubectl >/dev/null || return 2
  local before="" after=""
  [ -f "$HOME/.kube/config" ] && before="$(shasum "$HOME/.kube/config" | awk '{print $1}')"
  local shell out
  for shell in bash zsh; do
    command -v "$shell" >/dev/null || continue
    # An alias is planted first, so the shell is the one the bug needed.
    out="$("$shell" -c "shopt -s expand_aliases 2>/dev/null; alias k=kubectl
      cd '$SCRIPT_DIR/../..' && CLUSTER_NAME='$CLUSTER_NAME' AWS_REGION='$(registry_region)' \
        AWS_PROFILE='${AWS_PROFILE_OPT:-}' source scripts/distai-env.sh >/dev/null 2>&1
      printf '%s|%s|%s|%s' \"\$(type k 2>&1 | head -1)\" \"\$(type kubectl 2>&1 | head -1)\" \
        \"\$DISTAI_CONTEXT\" \"\$KUBECONFIG\"")"
    case "$out" in
      *"k is a function"* | *"k is a shell function"*) ;;
      *) printf '%s: k is not a function after sourcing: %s\n' "$shell" "$out" >&2; return 1 ;;
    esac
    case "$out" in
      *"kubectl is a function"* | *"kubectl is a shell function"*)
        printf '%s: sourcing redefined kubectl itself: %s\n' "$shell" "$out" >&2; return 1 ;;
    esac
    case "$out" in
      *"|${CLUSTER_NAME}|"*) ;;
      *) printf '%s: DISTAI_CONTEXT is not %s: %s\n' "$shell" "$CLUSTER_NAME" "$out" >&2; return 1 ;;
    esac
    case "$out" in
      *".kube/distai/${CLUSTER_NAME}."*) ;;
      *) printf '%s: KUBECONFIG is not this cluster and namespace: %s\n' "$shell" "$out" >&2; return 1 ;;
    esac
  done
  if [ -n "$before" ]; then
    after="$(shasum "$HOME/.kube/config" | awk '{print $1}')"
    [ "$before" = "$after" ] || {
      printf 'sourcing modified the default kubeconfig\n' >&2
      return 1
    }
  fi
  # And it must survive a caller that runs with set -eu, since chapters may source it from a script.
  bash -c "set -eu; cd '$SCRIPT_DIR/../..' && CLUSTER_NAME='$CLUSTER_NAME' AWS_REGION='$(registry_region)' \
    AWS_PROFILE='${AWS_PROFILE_OPT:-}' source scripts/distai-env.sh >/dev/null 2>&1" || {
    printf 'sourcing under set -eu failed\n' >&2
    return 1
  }
}

# A resolution that fails must not leave kubectl pointed at the cluster resolved before it. Otherwise a
# mistyped CLUSTER_NAME keeps working, against the wrong cluster, after a single warning.
test_registry_failed_resolve_drops_context() {
  local helper="$SCRIPT_DIR/../../scripts/distai-env.sh"
  [ -f "$helper" ] || return 2
  local out
  out="$(bash -c "cd '$SCRIPT_DIR/../..'
    CLUSTER_NAME='$CLUSTER_NAME' AWS_REGION='$(registry_region)' AWS_PROFILE='${AWS_PROFILE_OPT:-}' \
      source scripts/distai-env.sh >/dev/null 2>&1
    CLUSTER_NAME=no-such-cluster-\$\$ AWS_REGION='$(registry_region)' AWS_PROFILE='${AWS_PROFILE_OPT:-}' \
      source scripts/distai-env.sh >/dev/null 2>&1
    printf '%s|%s' \"\$DISTAI_CONTEXT\" \"\$KUBECONFIG\"")"
  [ "$out" = "|" ] || {
    printf 'a failed resolve left kubectl pointed somewhere: %s\n' "$out" >&2
    return 1
  }
}

# The registry's path layout and the state key's shape are decisions that several scripts and this
# suite all have to agree on. They are written out in each of them rather than derived from one place,
# so the tripwire is that they agree: a v2 of the layout, or a change to where a cluster's state lives,
# must not leave one file reading a namespace nobody else writes to.
test_registry_layout_is_stated_once() {
  local root="$SCRIPT_DIR/../../.."
  local files="$root/infra/scripts/distai-env.sh $root/infra/scripts/distai-up.sh
    $root/infra/scripts/distai-attach-data-layer.sh $root/infra/scripts/install-profiling.sh
    $SCRIPT_DIR/registry.sh"
  local prefixes keys
  # Every literal registry path, reduced to its schema part (/distai/<version>/clusters).
  prefixes="$(grep -hoE '/distai/[a-z0-9]+/clusters' $files | sort -u)"
  [ "$(printf '%s\n' "$prefixes" | grep -c .)" -eq 1 ] || {
    printf 'the registry path is spelled more than one way:\n%s\n' "$prefixes" >&2
    return 1
  }
  # And the state key: everything that names it must use the same shape.
  keys="$(grep -hoE 'eks/\$\{?[A-Za-z_]+\}?/terraform\.tfstate' $files | sed 's/\${*[A-Za-z_]*}*/CLUSTER/' | sort -u)"
  [ "$(printf '%s\n' "$keys" | grep -c .)" -le 1 ] || {
    printf 'the cluster state key is spelled more than one way:\n%s\n' "$keys" >&2
    return 1
  }
}

# The one-liner installers pin the release twice over on purpose: the URL a reader curls is from a tag,
# and the PIN inside the script it fetches is that same tag, so the tree that gets checked out is the
# tree the script was published with. That only holds if every copy of the release name agrees — and
# the name is written out in five places across two scripts and a doc, so a bump that misses one leaves
# a reader following the book against a tree the book was never written against. There is nothing at
# runtime that would notice, so it is asserted here.
# The pin above only has to agree with itself between releases: main carries the previous release's
# name until the bump lands. The moment a release tag points at a commit, though, the pin in that
# commit has to be that tag, or the URL a reader copies from the book installs a different tree than
# the one it names. That happened once: a tag was cut without bumping the pin, so the v0.2.1 URL
# cloned v0.2.0 and printed v0.2.0 back at the reader. Nothing at runtime notices, so the invariant
# is asserted here, at the only moment it can be checked. Off a tag there is nothing to compare, and
# the test skips.
test_registry_release_pin_matches_the_tag_here() {
  local script="$SCRIPT_DIR/../../scripts/check-release-pin.sh"
  [ -x "$script" ] || return 2
  local out rc=0
  out="$("$script" 2>&1)" || rc=$?
  case "$rc" in
    0) return 0 ;;
    3) return 2 ;;
    *) printf '%s\n' "$out" >&2; return 1 ;;
  esac
}

test_registry_release_pin_is_stated_once() {
  local root="$SCRIPT_DIR/../.."
  local found
  found="$(grep -rhoE 'release/eks-distributed-ai/v[0-9]+\.[0-9]+\.[0-9]+' \
    "$root/scripts/get-profiling.sh" "$root/scripts/distai-install.sh" \
    "$root/docs/profiling-install.md" 2>/dev/null | sort -u)"
  [ -n "$found" ] || { printf 'no release pin found at all; the greps are looking in the wrong place\n' >&2; return 1; }
  local n
  n="$(printf '%s\n' "$found" | grep -c .)"
  [ "$n" -eq 1 ] || {
    printf 'the release pin disagrees between the installers and the doc: %s\n' "$(printf '%s' "$found" | tr '\n' ' ')" >&2
    return 1
  }
  # The directory the installers clone into is derived from the pin, so the doc's `cd` has to follow it.
  local ver="${found##*/}"
  grep -qF "cd ~/distributed-ai-${ver}" "$root/docs/profiling-install.md" || {
    printf 'docs/profiling-install.md still cds into a directory from another release (pin is %s)\n' "$ver" >&2
    return 1
  }
}

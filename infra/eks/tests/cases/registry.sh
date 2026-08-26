#!/usr/bin/env bash
# Tests for the workshop registry and the two-line chapter preamble it exists to serve.
#
# The registry holds only what Terraform cannot: where a cluster's state lives, which release it was
# applied with, and which data layers are attached. That makes these tests worth having — a registry
# that has drifted from reality is invisible until a chapter resolves the wrong cluster, and the
# preamble is a contract (sourced, no exit, nothing on stdout) that a normal review would not catch
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

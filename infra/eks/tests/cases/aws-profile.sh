#!/usr/bin/env bash
# `export AWS_PROFILE=` is not "no profile" to the AWS CLI. It looks for a profile whose name is the
# empty string, finds none, and fails — and what it prints is about credentials or the resource being
# read, never about the empty string. So the symptom lands far from the cause. Measured against the
# registry: with AWS_PROFILE='' sourcing distai-env.sh ended in "cannot read the registry at
# /distai/v1/clusters/... in us-east-2" and left `k` as a bare alias, while the same shell with the
# variable unset succeeded.
#
# It has arrived from two directions, so both are checked. The tests themselves interpolated
# AWS_PROFILE='${AWS_PROFILE_OPT:-}', which sent an empty string on every run that chose no profile;
# and a reader's shell can carry an already-empty one in, which no amount of care inside the tests
# would neutralise. The first is a static rule about what may be written, the second is a behavioural
# one asserted against a stub CLI.
test_no_script_assigns_an_empty_aws_profile() {
  local script="$SCRIPT_DIR/portability/no-empty-aws-profile.sh"
  [ -x "$script" ] || { printf 'no-empty-aws-profile.sh is missing or not executable\n' >&2; return 1; }
  local out rc=0
  out="$("$script" 2>&1)" || rc=$?
  [ "$rc" = "0" ] || { printf '%s\n' "$out" >&2; return 1; }
}

# The static rule can only see the text that exists today. This one sources distai-env.sh with an empty
# AWS_PROFILE already exported and fails if a stub `aws` on PATH is reached with it still set. Only that
# script is exercised — the others have no help flag that returns before their preflight, so their guard
# is covered by the static check's position rule instead.
test_an_empty_aws_profile_never_reaches_the_cli() {
  local script="$SCRIPT_DIR/portability/empty-profile-behaviour.sh"
  [ -x "$script" ] || { printf 'empty-profile-behaviour.sh is missing or not executable\n' >&2; return 1; }
  local out rc=0
  out="$("$script" 2>&1)" || rc=$?
  [ "$rc" = "0" ] || { printf '%s\n' "$out" >&2; return 1; }
}

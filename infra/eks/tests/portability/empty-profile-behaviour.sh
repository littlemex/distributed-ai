#!/usr/bin/env bash
# empty-profile-behaviour.sh — prove that an empty AWS_PROFILE never reaches the AWS CLI.
#
# The static check next to this file forbids writing an empty AWS_PROFILE and requires every
# reader-facing script to neutralise one before it invokes anything. This one checks the half a static
# rule cannot: that the neutralisation actually happens at runtime. A stub `aws` stands in for the real
# CLI and records an offence if it is called with AWS_PROFILE or AWS_DEFAULT_PROFILE set to the empty
# string, or with an empty --profile among its arguments. Nothing here needs credentials, a cluster, or
# a network: every tool the script under test might reach is replaced.
#
# What is exercised, stated narrowly so it is not mistaken for more: distai-env.sh, sourced, once per
# variable. That is the one every chapter sources, it is where the failure was actually observed ("cannot
# read the registry ... in us-east-2", with `k` left as a bare alias), and sourcing is also the case
# where `unset` has to reach the caller rather than a subshell that exits anyway. The sourcing is
# expected to FAIL, because the stub returns no registry data — the assertion is about the environment
# the CLI was called in, not about the outcome, and the positive control below is what makes that
# distinction hold. The other scripts are not run: they have no help flag that returns before their
# preflight, and running a preflight under a stubbed PATH would let a test clone a repository and plan
# Terraform. Their guard is covered by the static check's text, column and position rules instead. Two
# further limits worth naming: a consumer that reads the variable through an SDK rather than the CLI (the
# Terraform AWS provider, boto3, a kubeconfig exec plugin) is invisible to a stub named `aws`, and the
# guard only protects paths that go through these scripts at all.
#
# Controls, because the failure mode that matters most here is passing while testing nothing:
#   - one negative control per detector in the stub, each isolated so that a poisoned environment cannot
#     make another detector produce the offence being looked for, and each checked by message rather than
#     by "the file is non-empty"
#   - a positive control requiring the exercised script to have called `aws` at all, so a change that
#     makes distai-env.sh return early becomes a failure rather than a green run
#
# Usage: bash empty-profile-behaviour.sh
# Exit: 0 nothing passed it through, 1 something did, 2 the check cannot run (which is never a pass).
set -euo pipefail

die() { printf '%s\n' "$*" >&2; exit 2; }

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd -- "${here}/../../../.." && pwd)"
[ -f "${root}/infra/scripts/distai-env.sh" ] ||
  die "cannot find infra/scripts/distai-env.sh from ${root}; this check is looking in the wrong place"

dir="$(mktemp -d)"
trap 'rm -rf "${dir}"' EXIT
mkdir -p "${dir}/bin"

# The stub records rather than exits, so the script under test keeps running and a later call cannot
# hide an earlier one. Every invocation is logged too, which is what the positive control reads.
cat >"${dir}/bin/aws" <<'STUB'
#!/usr/bin/env bash
printf 'aws %s\n' "$*" >>"${CALLS}"
if [ "${AWS_PROFILE+set}" = "set" ] && [ -z "${AWS_PROFILE}" ]; then
  printf 'empty AWS_PROFILE: aws %s\n' "$*" >>"${OFFENCES}"
fi
if [ "${AWS_DEFAULT_PROFILE+set}" = "set" ] && [ -z "${AWS_DEFAULT_PROFILE}" ]; then
  printf 'empty AWS_DEFAULT_PROFILE: aws %s\n' "$*" >>"${OFFENCES}"
fi
# Both spellings the CLI accepts: `--profile ""` and `--profile=`.
prev=""
for a in "$@"; do
  if [ "${prev}" = "--profile" ] && [ -z "${a}" ]; then
    printf 'empty --profile: aws %s\n' "$*" >>"${OFFENCES}"
  fi
  if [ "${a}" = "--profile=" ]; then
    printf 'empty --profile=: aws %s\n' "$*" >>"${OFFENCES}"
  fi
  prev="${a}"
done
case "$*" in
  *"get-caller-identity"*) printf 'arn:aws:iam::000000000000:user/stub\n' ;;
  *) printf '\n' ;;
esac
STUB
chmod +x "${dir}/bin/aws"
# Every tool is stubbed unconditionally. Leaving the real one in place whenever it existed made "this
# needs no network" a claim about what distai-env.sh happens to call today; the day a preflight grows a
# `kubectl version`, a test would start talking to a cluster. If a stub that returns nothing ever breaks
# the positive control, the fix is to give that stub the minimum output needed, not to remove it.
for t in terraform kubectl helm curl git python3 shasum; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"${dir}/bin/${t}"
  chmod +x "${dir}/bin/${t}"
done

offences="${dir}/offences.txt"; : >"${offences}"
calls="${dir}/calls.txt"; : >"${calls}"

# One negative control per detector. Each runs with every profile variable unset except the one under
# test, so an empty variable in this machine's own environment cannot supply the offence another
# detector was supposed to find, and each is matched by message so that a detector cannot be covered for
# by a different one firing.
control() {
  local want="$1"; shift
  : >"${offences}"
  ( env -u AWS_PROFILE -u AWS_DEFAULT_PROFILE OFFENCES="${offences}" CALLS="${calls}" \
      "$@" >/dev/null ) || die "the stub itself failed while being handed ${want}"
  grep -q "^${want}:" "${offences}" ||
    die "the stub did not record '${want}' when it was handed exactly that; this check cannot detect it"
}
control "empty AWS_PROFILE"         env AWS_PROFILE=         "${dir}/bin/aws" sts get-caller-identity
control "empty AWS_DEFAULT_PROFILE" env AWS_DEFAULT_PROFILE= "${dir}/bin/aws" sts get-caller-identity
control "empty --profile"           "${dir}/bin/aws" sts get-caller-identity --profile ""
control "empty --profile="          "${dir}/bin/aws" sts get-caller-identity --profile=
: >"${offences}"
: >"${calls}"

# --noprofile --norc and the cleared BASH_ENV/ENV matter for the positive control: a startup file that
# happened to call aws would make "the CLI was reached" true without distai-env.sh doing anything.
# KUBECONFIG is emptied for the same reason the tools are stubbed — nothing here may depend on, or
# touch, whatever cluster this machine is pointed at.
exercise() {
  local var="$1"
  : >"${offences}"; : >"${calls}"
  ( cd "${root}/infra" &&
    env -u BASH_ENV -u ENV -u AWS_PROFILE -u AWS_DEFAULT_PROFILE \
      OFFENCES="${offences}" CALLS="${calls}" PATH="${dir}/bin:${PATH}" KUBECONFIG= \
      CLUSTER_NAME=stub-cluster AWS_REGION=us-east-2 "${var}=" \
      bash --noprofile --norc -c 'source scripts/distai-env.sh >/dev/null 2>&1; exit 0' ) || true
  [ -s "${calls}" ] ||
    die "sourcing distai-env.sh with ${var} empty never called aws, so nothing was observed; fix this check"
  if [ -s "${offences}" ]; then
    printf 'an empty %s reached the AWS CLI:\n' "${var}" >&2
    sort -u "${offences}" >&2
    printf '\nAdd near the top of the script, before anything is invoked:\n  %s\n  %s\n' \
      '[ -n "${AWS_PROFILE:-}" ] || unset AWS_PROFILE' \
      '[ -n "${AWS_DEFAULT_PROFILE:-}" ] || unset AWS_DEFAULT_PROFILE' >&2
    return 1
  fi
  printf 'sourcing distai-env.sh with %s empty reached the CLI %s time(s) and never passed it on\n' \
    "${var}" "$(wc -l <"${calls}" | tr -d ' ')"
}
rc=0
exercise AWS_PROFILE || rc=1
exercise AWS_DEFAULT_PROFILE || rc=1
exit "${rc}"

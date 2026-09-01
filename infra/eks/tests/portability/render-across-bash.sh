#!/usr/bin/env bash
# render-across-bash.sh — build the manifests kubectl-accelprof would submit, using only this bash.
#
# The reader's own bash assembles what they submit, and bash changed what a substitution does with its
# replacement text: '&' means the matched text, and a backslash escapes it, only from 5.2. Code written
# for one era corrupts the other. That is how `--gpu 1` came to fail with "found unknown escape
# character" on bash 3.2 and 5.1 while passing for a developer whose PATH found 5.2 first — measured,
# not supposed.
#
# So the invariant is not "this construct is safe" but "every bash renders the same accepted manifest".
# This drives the real tool rather than a copy of its helpers, so it keeps testing the code that ships.
# The device cases are the ones that broke, and they are also the ones that reach a YAML parser: they go
# through `kubectl patch --local`, which is why the corruption surfaced there first. kubectl is needed
# for those; without it they are skipped rather than silently reported as agreeing.
#
# Usage: bash render-across-bash.sh <path-to-kubectl-accelprof> <output-dir>
# Exit: 0 every case rendered, 1 a case the tool should have rendered failed, 2 cannot run at all.
set -u

plugin="${1:?usage: render-across-bash.sh <plugin> <outdir>}"
outdir="${2:?usage: render-across-bash.sh <plugin> <outdir>}"
[ -x "${plugin}" ] || { printf 'render-across-bash: cannot execute %s\n' "${plugin}" >&2; exit 2; }
mkdir -p "${outdir}" || exit 2
printf 'render-across-bash: bash %s\n' "${BASH_VERSION}" >&2

have_kubectl=false
command -v kubectl >/dev/null && have_kubectl=true

status=0
emit() {
  local label="$1"; shift
  local needs_kubectl="$1"; shift
  if [ "${needs_kubectl}" = "yes" ] && [ "${have_kubectl}" != "true" ]; then
    printf 'render-across-bash: skipped %s (no kubectl)\n' "${label}" >&2
    return
  fi
  local out="" rc=0
  out="$(ACCELPROF_PLATFORM_IMAGE="image.example/accelprof@sha256:0" KUBE_CONTEXT="" \
    "${plugin}" run --alias t-s --namespace ns --image image.example/w:t --dry-run "$@" 2>&1)" || rc=$?
  # The workload id carries a timestamp and a random suffix, so it differs between two runs of one bash
  # as much as between two versions. Blanking it leaves a manifest whose every remaining byte is meant
  # to be identical everywhere.
  printf '%s\n' "${out}" | sed -e 's/wl-[0-9]\{12\}-[0-9a-f]\{8\}/wl-NORMALISED/g' >"${outdir}/${label}.txt"
  if [ "${rc}" != "0" ]; then
    printf 'render-across-bash: %s failed (exit %s): %s\n' "${label}" "${rc}" "$(printf '%s' "${out}" | head -1)" >&2
    status=1
    return
  fi
  case "${out}" in
    *"kind: Job"*) ;;
    *) printf 'render-across-bash: %s produced no manifest\n' "${label}" >&2; status=1 ;;
  esac
}

# No device: the manifest is printed without ever being parsed, so this is the case that can regress
# invisibly. With a device: the tool merges a strategic patch through `kubectl patch --local`, which is
# the first thing to read the text as YAML — the case that actually broke.
emit plain            no  -- true
emit and-in-command   no  -- sh -c 'mkdir -p /a && cp -a /x/. /y/'
emit amp-in-param     no  --param 'note=a & b' -- true
emit backslash-param  no  --param 'note=back\slash' -- true
emit quote-in-param   no  --param 'note=quote"inside' -- true
emit hash-percent     no  --param 'note=percent%and#hash' -- true
emit gpu              yes --gpu 1 -- true
emit gpu-and-command  yes --gpu 1 -- sh -c 'mkdir -p /a && cp -a /x/. /y/'
emit neuron           yes --neuron 2 -- true
emit gpu-amp-nsys     yes --gpu 1 --nsys-args '-t cuda,nvtx & osrt' -- true
emit gpu-env          yes --gpu 1 --env 'NOTE=a & b' -- true
exit "${status}"

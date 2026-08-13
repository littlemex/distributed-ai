#!/usr/bin/env bash
# In-cluster image builder (rootless BuildKit -> ECR) static tests. The build/push Job is the
# reusable experiments.imageBuildJob define (charts/experiments/templates/_image-build.tpl); the
# ddp-sample workshop image is a thin caller (image-build-ddp-sample.yaml) and image-build-custom.yaml
# is the generic caller. These render chart sources with `helm template` (static layer, no cluster)
# to lock what the workshop/book depend on and to check the generic path + the fail-loud guards.
# Layer/suite are declared in registry.sh.

_ib_chart="$SCRIPT_DIR/../charts/experiments"
_ib_repo="111122223333.dkr.ecr.ap-northeast-1.amazonaws.com/distai-eks-ddp-sample"
_ib_golden="$SCRIPT_DIR/golden/image-build-ddp-sample.git.yaml"

_ib_helm() { helm template exp "$_ib_chart" "$@" 2>&1; }

# BEHAVIOR LOCK: the ddp-sample git render must stay byte-identical (the book cites this Job's name
# and the helm command). A full golden diff catches ANY drift (name, args, resources, securityContext),
# not just a couple of grepped lines. Regenerate the golden intentionally if ddp-sample really changes:
#   out=$(helm template exp charts/experiments -s templates/image-build-ddp-sample.yaml \
#     --set imageBuild.enabled=true \
#     --set imageBuild.repository=111122223333.dkr.ecr.ap-northeast-1.amazonaws.com/distai-eks-ddp-sample \
#     --set imageBuild.tag=v1); printf '%s\n' "$out" > tests/golden/image-build-ddp-sample.git.yaml
test_image_build_ddp_sample_golden() {
  command -v helm >/dev/null 2>&1 || return 2
  local out
  out=$(_ib_helm -s templates/image-build-ddp-sample.yaml \
        --set imageBuild.enabled=true --set imageBuild.repository="$_ib_repo" --set imageBuild.tag=v1) \
    || { printf 'render failed:\n%s\n' "$out"; return 1; }
  printf '%s\n' "$out" | diff -u "$_ib_golden" - \
    || { echo "ddp-sample git render drifted from tests/golden (behavior lock; regenerate intentionally if ddp-sample changed)"; return 1; }
  return 0
}

# The generic caller builds a DIFFERENT image with its OWN identity (Job name, repo) — not the
# ddp-sample name — and is the intended path for a configMap context. Also assert the selector:
# without jobName it renders no Job (so it can never break -s renders of other templates).
test_image_build_custom_render() {
  command -v helm >/dev/null 2>&1 || return 2
  local out
  out=$(_ib_helm -s templates/image-build-custom.yaml \
        --set imageBuild.enabled=true --set imageBuild.jobName=build-my-app \
        --set imageBuild.repository="$_ib_repo" --set imageBuild.tag=v1 \
        --set imageBuild.contextSource=configMap --set imageBuild.contextConfigMap=my-ctx) \
    || { printf 'custom configMap render failed:\n%s\n' "$out"; return 1; }
  printf '%s\n' "$out" | grep -q "name: build-my-app-v1" || { echo "custom: Job not named for the image"; return 1; }
  printf '%s\n' "$out" | grep -q "name: stage-context"   || { echo "custom: stage-context initContainer missing"; return 1; }
  printf '%s\n' "$out" | grep -q "context=/workspace"    || { echo "custom: local build context missing"; return 1; }

  # No jobName -> the selector renders nothing. helm --show-only on an empty render exits non-zero
  # ("could not find template … in chart"); that is the no-op, so we assert only that no Job appears.
  out=$(_ib_helm -s templates/image-build-custom.yaml \
        --set imageBuild.enabled=true --set imageBuild.repository="$_ib_repo" --set imageBuild.tag=v1)
  printf '%s\n' "$out" | grep -q "kind: Job" \
    && { echo "custom rendered a Job without jobName (selector must be a no-op)"; return 1; }
  return 0
}

# The two callers are mutually exclusive on jobName: a full render (no -s) with a jobName set must
# yield exactly ONE Job (the custom one), never both — else two Jobs push to the same repo:tag.
test_image_build_callers_exclusive() {
  command -v helm >/dev/null 2>&1 || return 2
  local out n
  out=$(_ib_helm --set imageBuild.enabled=true --set imageBuild.jobName=build-my-app \
        --set imageBuild.repository="$_ib_repo" --set imageBuild.tag=v1 \
        --set imageBuild.contextSource=configMap --set imageBuild.contextConfigMap=my-ctx) \
    || { printf 'full render failed:\n%s\n' "$out"; return 1; }
  n=$(printf '%s\n' "$out" | grep -c '^kind: Job')
  [ "$n" = "1" ] || { echo "expected exactly 1 Job with jobName set, got $n (callers not mutually exclusive)"; return 1; }
  printf '%s\n' "$out" | grep -q "name: build-ddp-sample-" \
    && { echo "ddp-sample Job rendered alongside the custom Job (identity collision)"; return 1; }
  # default (no jobName) full render is the ddp-sample Job, exactly one
  out=$(_ib_helm --set imageBuild.enabled=true --set imageBuild.repository="$_ib_repo" --set imageBuild.tag=v1) \
    || { printf 'default full render failed:\n%s\n' "$out"; return 1; }
  n=$(printf '%s\n' "$out" | grep -c '^kind: Job')
  [ "$n" = "1" ] || { echo "expected exactly 1 Job by default, got $n"; return 1; }
  return 0
}

# want-fail: the render must fail AND for the stated reason (not vacuously "some failure").
_ib_must_fail() {
  local want="$1"; shift
  local out; out=$(_ib_helm "$@")
  if [ $? -eq 0 ]; then echo "expected failure but render succeeded: helm $*"; return 1; fi
  printf '%s\n' "$out" | grep -qF "$want" || { printf "failed for the wrong reason (want %q):\n%s\n" "$want" "$out"; return 1; }
  return 0
}

# Misconfiguration fails at render time (no silent no-op / no silent wrong-build), each for its own
# reason.
test_image_build_guards() {
  command -v helm >/dev/null 2>&1 || return 2
  local G="-s templates/image-build-ddp-sample.yaml --set imageBuild.enabled=true --set imageBuild.repository=$_ib_repo --set imageBuild.tag=v1"
  _ib_must_fail 'contextSource must be'        $G --set imageBuild.contextSource=configmap || return 1
  _ib_must_fail 'contextConfigMap is set but'  $G --set imageBuild.contextConfigMap=oops   || return 1
  _ib_must_fail 'contextConfigMap is required' $G --set imageBuild.contextSource=configMap || return 1
  _ib_must_fail 'filename must match'          $G --set imageBuild.filename=bad/name       || return 1
  _ib_must_fail 'contextSubPath must match'    $G --set 'imageBuild.contextSubPath=a b'     || return 1
  # tag that would make an invalid Job name (uppercase/dot/@/comma) fails at render, not apply
  _ib_must_fail 'must be a DNS-1123 label' -s templates/image-build-ddp-sample.yaml --set imageBuild.enabled=true \
        --set imageBuild.repository=$_ib_repo --set imageBuild.tag=bad@tag || return 1
  return 0
}

#!/usr/bin/env bash
# Run one episode in the instance's own evaluation image, as a Kubernetes Job.
#
#   export KUBE_CONTEXT=<context>  STRATOCLAVE_HOST=<gateway host>  STRATOCLAVE_API_KEY=<token>
#   ./run.sh psf__requests-1142 premium-always
#
# The image is the instance's official one, so the repository, its dependencies and a conda
# environment that can run its suite are already there. This script only adds the harness,
# the instance data and the credentials, then runs the loop and the scorer in that order —
# the scorer applies the tests, so it has to be second or the agent could read them.
#
# Nothing environment-specific is written into the repository: the gateway host and token
# come from the environment and go into a Secret, and the instance data goes into a
# ConfigMap built at submit time.
set -euo pipefail

INSTANCE_ID="${1:?usage: run.sh <instance_id> <policy>}"
POLICY="${2:-cheap-then-escalate}"
NAMESPACE="${NAMESPACE:-swe-pilot}"
HERE="$(cd "$(dirname "$0")" && pwd)"
: "${KUBE_CONTEXT:?set KUBE_CONTEXT to the target cluster}"
: "${STRATOCLAVE_HOST:?set STRATOCLAVE_HOST to the gateway host}"
: "${STRATOCLAVE_API_KEY:?set STRATOCLAVE_API_KEY to the gateway bearer token}"
: "${STRATOCLAVE_DEFAULTS:?set STRATOCLAVE_DEFAULTS to backend/mvp/defaults in the gateway repository}"

KC="kubectl --context ${KUBE_CONTEXT} -n ${NAMESPACE}"
# Lower-cased and with the double underscore flattened: a Job name is a DNS label.
SAFE_ID="$(echo "${INSTANCE_ID}" | tr '[:upper:]_' '[:lower:]-')"
JOB="ep-${SAFE_ID}-$(echo "${POLICY}" | tr -d '[:space:]')"
JOB="${JOB:0:57}${PASS:+-p${PASS}}"
# A repeat of the same (instance, policy) writes beside the first rather than over it: the
# re-run flip rate is one of the four things the pilot has to measure, and it needs both
# answers. `PASS=2` puts them under /results/pass2/, one level deeper, which is why the
# report's first-pass glob does not pick them up.
PASS_DIR="${PASS:+pass${PASS}/}"
# The protocol is part of what an episode is, not a setting on top of it, so a function-calling
# episode must not land on a text one. Pass PASS=fc alongside PROTOCOL=function-calling.
IMAGE="swebench/sweb.eval.x86_64.${INSTANCE_ID//__/_1776_}:latest"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo "[INFO] ${INSTANCE_ID} / ${POLICY} / ${IMAGE}"

# Cached outside the repository: submitting a sweep of a hundred episodes means asking the
# datasets server for the same five pages a hundred times, which is slow and eventually
# answered with a 429 halfway through a run.
CACHE="${SWEBENCH_CACHE:-${HOME}/.cache/swebench-verified.json}"
mkdir -p "$(dirname "${CACHE}")"

PYTHONPATH="${HERE}" python3 - "$INSTANCE_ID" "${WORK}/instance.json" "${CACHE}" <<'PY'
import json, sys
from pathlib import Path
import dataset
wanted, out, cache = sys.argv[1], sys.argv[2], Path(sys.argv[3])
match = [i for i in dataset.load(cache) if i.instance_id == wanted]
if not match:
    raise SystemExit(f"[FAIL] no instance called {wanted}")
i = match[0]
json.dump(
    {
        "instance_id": i.instance_id,
        "repo": i.repo,
        "base_commit": i.base_commit,
        "problem_statement": i.problem_statement,
        "difficulty": i.difficulty,
        "fail_to_pass": list(i.fail_to_pass),
        "pass_to_pass": list(i.pass_to_pass),
        "gold_patch": i.gold_patch,
        "test_patch": i.test_patch,
    },
    open(out, "w"),
)
size = len(open(out).read())
if size > 900_000:
    # A ConfigMap holds one mebibyte. Better to say so than to have kubectl refuse a Job
    # after the image has already been pulled.
    raise SystemExit(f"[FAIL] {i.instance_id} is {size:,} bytes, too large for a ConfigMap")
print(f"[OK] {i.instance_id}: {len(i.fail_to_pass)} fail-to-pass, "
      f"{len(i.pass_to_pass)} pass-to-pass, {size:,} bytes")
PY

# The gateway address is a deployment fact, so it is injected here rather than committed.
# Note for anyone editing the guards above: an apostrophe inside ${VAR:?message} opens a
# quote in bash and swallows the rest of the file.
# TIERS names the file, because which model a tier is and how it is configured are properties of
# an arm rather than of the harness: the function-calling arm has to run gpt-5.6-terra with
# reasoning off, since this gateway refuses function tools together with reasoning_effort on
# /v1/chat/completions, and that is a different configuration which must be visible in the arm's
# definition instead of hidden behind a flag.
python3 - "${TIERS:-${HERE}/tiers.example.json}" "${WORK}/tiers.json" "https://${STRATOCLAVE_HOST}/v1/chat/completions" <<'PY'
import json, sys
src, out, url = sys.argv[1], sys.argv[2], sys.argv[3]
tiers = {k: v for k, v in json.load(open(src)).items() if not k.startswith("_")}
for tier, entry in tiers.items():
    if tier != "self_hosted":
        # A tier that speaks the Responses API needs the other path on the same host. The base is
        # passed in as the chat path because that is what every other tier wants.
        entry["url"] = (
            url.replace("/v1/chat/completions", "/openai/v1/responses")
            if entry.get("api") == "responses" else url
        )
    elif not entry.get("url"):
        entry["url"] = __import__("os").environ.get("QWEN_LOCAL_ENDPOINT_URL", "")
json.dump(tiers, open(out, "w"), indent=2)
PY

cp "${STRATOCLAVE_DEFAULTS}/pricing.json" "${WORK}/pricing.json"

# `SCORE_ONLY=1` scores a diff that is already on the volume, without spending anything. Two
# occasions need it: the scorer was corrected after episodes had run — colour codes in a
# repository's own test output had made 179 passing tests read as an instance that could not be
# scored — and a verdict is cheap to recompute while an episode is not.
if [[ -n "${SCORE_ONLY:-}" ]]; then
  EPISODE_CMD='echo "[INFO] score-only: the diff already on the volume, no model calls"; test -f "$OUT/diff.patch" || { echo "[FAIL] no diff at $OUT/diff.patch"; exit 1; }; status=0'
else
  EPISODE_CMD='"$HARNESS_PY" /code/loop.py --instance /data/instance.json --tiers /data/tiers.json --pricing /data/pricing.json --policy '"${POLICY}"' --out "$OUT" --max-steps ${MAX_STEPS:-40} --max-tokens ${MAX_TOKENS:-1200000} --max-usd ${MAX_USD:-20.0} --protocol ${PROTOCOL:-text} 2>&1 | tee "$OUT/loop.log"; status=$?'
fi

# Results go to a shared volume, not to the pod. The first role-based episode finished, its
# node was consolidated moments later, and the pod took its logs and its episode.json with
# it — a completed run with nothing to show is the same as a run that never happened.
cat <<YAML | $KC apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: episode-results
spec:
  accessModes: [ReadWriteMany]
  storageClassName: efs-shared
  resources:
    requests:
      storage: 20Gi
YAML

$KC delete job "${JOB}" --ignore-not-found >/dev/null
$KC create configmap "${JOB}-code" \
  --from-file="${HERE}/loop.py" --from-file="${HERE}/tools.py" \
  --from-file="${HERE}/policy.py" --from-file="${HERE}/transport.py" \
  --from-file="${HERE}/score.py" \
  --dry-run=client -o yaml | $KC apply -f - >/dev/null
$KC create configmap "${JOB}-data" \
  --from-file="${WORK}/instance.json" --from-file="${WORK}/tiers.json" \
  --from-file="${WORK}/pricing.json" \
  --dry-run=client -o yaml | $KC apply -f - >/dev/null
$KC create secret generic "${JOB}-creds" \
  --from-literal=api-key="${STRATOCLAVE_API_KEY}" \
  --dry-run=client -o yaml | $KC apply -f - >/dev/null

cat <<YAML | $KC apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 86400
  # A runaway guard only. The loop stops itself on steps and on spend; this is for the case
  # where a call neither answers nor fails, which in a sweep would stall every episode behind
  # it. Well above the longest episode measured, so it is not a condition of the experiment.
  activeDeadlineSeconds: ${EPISODE_DEADLINE:-3600}
  template:
    metadata:
      annotations:
        # An episode cannot be interrupted and resumed: it is a conversation with a model, and
        # a pod that dies at step 22 has spent the money and has nothing to show. Karpenter
        # consolidated a node under four running episodes and the taint manager evicted them
        # all, so a running episode now holds its node until it is finished.
        karpenter.sh/do-not-disrupt: "true"
    spec:
      restartPolicy: Never
      containers:
        - name: episode
          image: ${IMAGE}
          command: ["/bin/bash", "-lc"]
          args:
            - |
              set -o pipefail
              OUT=/results/${PASS_DIR}${INSTANCE_ID}/${POLICY}
              mkdir -p "\$OUT"
              cd /work
              # The harness needs a 3.7 interpreter and the image's default is whatever the
              # repository needed: scikit-learn 0.21 and Django 3.0 ship 3.6.13, where the
              # harness would not even parse and five episodes died before their first call.
              # The tests still run in the repository's own environment — the agent's tools
              # activate it explicitly — so this only decides what runs the loop.
              for candidate in /opt/miniconda3/bin/python3 /usr/bin/python3 python3 python; do
                if command -v "\$candidate" >/dev/null 2>&1 && "\$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 7) else 1)' >/dev/null 2>&1; then
                  HARNESS_PY="\$candidate"; break
                fi
              done
              if [ -z "\${HARNESS_PY:-}" ]; then
                echo "[FAIL] this image has no interpreter at 3.7 or above" | tee "\$OUT/loop.log"
                exit 1
              fi
              echo "[INFO] harness on \$HARNESS_PY (\$("\$HARNESS_PY" -V 2>&1))"
              ${EPISODE_CMD}
              echo "--- scoring (the tests are applied only now) ---"
              "\$HARNESS_PY" /code/score.py --instance /data/instance.json \\
                --diff "\$OUT/diff.patch" --out "\$OUT/score.json" 2>&1 \\
                | tee "\$OUT/score.log"
              echo "--- episode.json ---"
              cat "\$OUT/episode.json"
              echo "--- score.json ---"
              cat "\$OUT/score.json"
              exit \$status
          env:
            # The token budget is the same for every arm, and it has to be loose enough that
            # the policy decides how an episode ends. At 400,000 it was not: the premium arm
            # finished on its own in eight turns and 120,000 tokens, while every other arm was
            # cut off mid-episode — which is the dollar ceiling's objection in another currency,
            # and it fell on exactly the arms whose non-inferiority is the question. 1,200,000
            # lets forty steps happen at the ~25,000 tokens a step this corpus produces, so the
            # step limit is the pre-registered bound again.
            - name: MAX_TOKENS
              value: "${MAX_TOKENS:-1200000}"
            - name: STRATOCLAVE_API_KEY
              valueFrom:
                secretKeyRef: {name: ${JOB}-creds, key: api-key}
            - name: MAX_STEPS
              value: "${MAX_STEPS:-40}"
            - name: MAX_USD
              value: "${MAX_USD:-20.0}"
            - name: VLLM_METRICS_URL
              value: "${VLLM_METRICS_URL:-}"
            - name: PROTOCOL
              value: "${PROTOCOL:-text}"
          volumeMounts:
            - {name: code, mountPath: /code}
            - {name: data, mountPath: /data}
            - {name: work, mountPath: /work}
            - {name: results, mountPath: /results}
          resources:
            # ephemeral-storage is requested explicitly, and that is not boilerplate: the instance
            # images are 1-3 GB each, a node holds 20 GiB, and nothing tells the scheduler that a
            # pod is about to pull one. Several episodes on one node put the kubelet into
            # DiskPressure and it evicted a running episode mid-pull -- twice, on the same node,
            # for matplotlib. Declaring the pull's footprint is what makes the scheduler spread
            # them; `jobs/agentx.yaml` carries the same note for the same reason.
            requests: {cpu: "1", memory: 4Gi, ephemeral-storage: 8Gi}
            limits: {cpu: "4", memory: 12Gi, ephemeral-storage: 24Gi}
      volumes:
        - {name: code, configMap: {name: ${JOB}-code}}
        - {name: data, configMap: {name: ${JOB}-data}}
        - {name: work, emptyDir: {}}
        - {name: results, persistentVolumeClaim: {claimName: episode-results}}
YAML

echo "[INFO] follow with:"
echo "  kubectl --context ${KUBE_CONTEXT} -n ${NAMESPACE} logs -f job/${JOB}"
echo "[INFO] results land on the shared volume at /results/${PASS_DIR}${INSTANCE_ID}/${POLICY}/"
echo "       and survive the pod: ./collect.sh copies them out"

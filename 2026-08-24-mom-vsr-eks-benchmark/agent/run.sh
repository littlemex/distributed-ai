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
JOB="${JOB:0:60}"
IMAGE="swebench/sweb.eval.x86_64.${INSTANCE_ID//__/_1776_}:latest"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo "[INFO] ${INSTANCE_ID} / ${POLICY} / ${IMAGE}"

PYTHONPATH="${HERE}" python3 - "$INSTANCE_ID" "${WORK}/instance.json" <<'PY'
import json, sys
import dataset
wanted, out = sys.argv[1], sys.argv[2]
match = [i for i in dataset.load() if i.instance_id == wanted]
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
python3 - "${HERE}/tiers.example.json" "${WORK}/tiers.json" "https://${STRATOCLAVE_HOST}/v1/chat/completions" <<'PY'
import json, sys
src, out, url = sys.argv[1], sys.argv[2], sys.argv[3]
tiers = {k: v for k, v in json.load(open(src)).items() if not k.startswith("_")}
for tier, entry in tiers.items():
    if tier != "self_hosted":
        entry["url"] = url
    elif not entry.get("url"):
        entry["url"] = __import__("os").environ.get("QWEN_LOCAL_ENDPOINT_URL", "")
json.dump(tiers, open(out, "w"), indent=2)
PY

cp "${STRATOCLAVE_DEFAULTS}/pricing.json" "${WORK}/pricing.json"

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
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: episode
          image: ${IMAGE}
          command: ["/bin/bash", "-lc"]
          args:
            - |
              set -o pipefail
              OUT=/results/${INSTANCE_ID}/${POLICY}
              mkdir -p "\$OUT"
              cd /work
              python /code/loop.py --instance /data/instance.json \\
                --tiers /data/tiers.json --pricing /data/pricing.json \\
                --policy ${POLICY} --out "\$OUT" \\
                --max-steps \${MAX_STEPS:-40} --max-usd \${MAX_USD:-20.0} \\
                2>&1 | tee "\$OUT/loop.log"
              status=\$?
              echo "--- scoring (the tests are applied only now) ---"
              python /code/score.py --instance /data/instance.json \\
                --diff "\$OUT/diff.patch" --out "\$OUT/score.json" 2>&1 \\
                | tee "\$OUT/score.log"
              echo "--- episode.json ---"
              cat "\$OUT/episode.json"
              echo "--- score.json ---"
              cat "\$OUT/score.json"
              exit \$status
          env:
            - name: STRATOCLAVE_API_KEY
              valueFrom:
                secretKeyRef: {name: ${JOB}-creds, key: api-key}
            - name: MAX_STEPS
              value: "${MAX_STEPS:-40}"
            - name: MAX_USD
              value: "${MAX_USD:-20.0}"
            - name: VLLM_METRICS_URL
              value: "${VLLM_METRICS_URL:-}"
          volumeMounts:
            - {name: code, mountPath: /code}
            - {name: data, mountPath: /data}
            - {name: work, mountPath: /work}
            - {name: results, mountPath: /results}
          resources:
            requests: {cpu: "1", memory: 4Gi}
            limits: {cpu: "4", memory: 12Gi}
      volumes:
        - {name: code, configMap: {name: ${JOB}-code}}
        - {name: data, configMap: {name: ${JOB}-data}}
        - {name: work, emptyDir: {}}
        - {name: results, persistentVolumeClaim: {claimName: episode-results}}
YAML

echo "[INFO] follow with:"
echo "  kubectl --context ${KUBE_CONTEXT} -n ${NAMESPACE} logs -f job/${JOB}"
echo "[INFO] results land on the shared volume at /results/${INSTANCE_ID}/${POLICY}/"
echo "       and survive the pod: ./collect.sh copies them out"

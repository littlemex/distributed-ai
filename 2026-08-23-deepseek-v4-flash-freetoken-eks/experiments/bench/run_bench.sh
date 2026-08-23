#!/usr/bin/env bash
# Run the latency/throughput benchmark as an in-cluster Job against the freetoken-serving alias.
#
#   ./experiments/bench/run_bench.sh [--concurrency 1,2,4] [--max-tokens 128] [--follow]
#
# In-cluster on purpose: measuring from a workstation over kubectl port-forward would fold a
# single TCP hop through the API server into every TTFT sample and cap throughput at the tunnel's
# rate, so the numbers would describe the tunnel, not the engine.
set -euo pipefail
export AWS_PAGER=""

HERE="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$HERE"

CONC="1,2,4"; MAXTOK=128; FOLLOW=0
while [ $# -gt 0 ]; do case "$1" in
  --concurrency) CONC="${2:?}"; shift 2;;
  --max-tokens) MAXTOK="${2:?}"; shift 2;;
  --follow) FOLLOW=1; shift;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done

NS="${FT_NAMESPACE:-freetoken}"
CTX="${FT_KUBE_CONTEXT:-$(kubectl config current-context)}"
K=(kubectl --context "$CTX" -n "$NS")
JOB="ft-bench"

log(){ printf '\n\033[1;32m[bench]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[bench][FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

"${K[@]}" get svc freetoken-serving >/dev/null 2>&1 \
  || die "Service freetoken-serving not found in $NS; deploy a profile first"

"${K[@]}" delete job "$JOB" --ignore-not-found --wait=true >/dev/null 2>&1 || true
"${K[@]}" create configmap "$JOB-src" --from-file=bench.py=experiments/bench/bench.py \
  --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null

kubectl --context "$CTX" apply -f - <<YAML >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB
  namespace: $NS
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      # CPU pool: the benchmark client must not compete with the engine for the GPU node's cores,
      # or a high-concurrency point would measure contention on the client side.
      nodeSelector: { node-role: cpu }
      containers:
        - name: bench
          image: public.ecr.aws/docker/library/python:3.12-slim
          command: ["python", "/src/bench.py"]
          args:
            - --base=http://freetoken-serving:1919
            - --concurrency=$CONC
            - --max-tokens=$MAXTOK
          volumeMounts:
            - { name: src, mountPath: /src }
          resources:
            requests: { cpu: "1", memory: 512Mi }
            limits: { memory: 1Gi }
      volumes:
        - name: src
          configMap: { name: $JOB-src }
YAML

log "Job $JOB started (concurrency=$CONC, max_tokens=$MAXTOK)"
if [ "$FOLLOW" = 1 ]; then
  "${K[@]}" wait --for=condition=ready pod -l job-name="$JOB" --timeout=5m >/dev/null 2>&1 || true
  "${K[@]}" logs -f "job/$JOB"
else
  echo "  follow it with: kubectl --context $CTX -n $NS logs -f job/$JOB"
fi

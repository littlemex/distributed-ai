#!/usr/bin/env bash
# Submit one AgentX arm. Concurrency and duration are the arm; everything else is fixed so two arms
# differ only in the thing being swept.
#
#   ./scripts/submit-agentx.sh <name> <concurrency> <duration_s>
#
# The per-replica Prometheus URLs are resolved here rather than in the pod, because scraping them
# needs pod IPs and the alternative is giving the benchmark client RBAC on the cluster to look up the
# server it is measuring. Both replicas are scraped: the Service would give one of two, and KV-cache
# hit rate averaged over half a box is not the box's.
set -euo pipefail
NAME="${1:?usage: submit-agentx.sh <name> <concurrency> <duration_s>}"
CONC="${2:?}"
DURATION="${3:?}"
CTX="${BENCHCTL_KUBE_CONTEXT:-distai-eks}"
NS="${BENCHCTL_NAMESPACE:-swe-pilot}"
SERVING_NS="${SERVING_NAMESPACE:-qwen-trial}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"; cd "$HERE"

ips="$(kubectl --context "$CTX" -n "$SERVING_NS" get pod \
  -l app.kubernetes.io/name=vllm-serving --field-selector=status.phase=Running \
  -o jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}')"
[ -n "$ips" ] || { echo "no running vllm-serving pods in $SERVING_NS" >&2; exit 1; }
metrics="$(printf 'http://%s:8000/metrics,' $ips | sed 's/,$//')"
echo "[submit] scraping $(echo "$ips" | wc -l | tr -d ' ') replica(s): $metrics"

kubectl --context "$CTX" -n "$NS" create configmap agentx-code \
  --from-file=run.sh=instruments/agentx/run.sh --dry-run=client -o yaml \
  | kubectl --context "$CTX" -n "$NS" apply -f - >/dev/null

kubectl --context "$CTX" -n "$NS" delete job "agentx-$NAME" --ignore-not-found >/dev/null 2>&1 || true
sleep 2
python3 - "$NAME" "$CONC" "$DURATION" "$metrics" <<'PY' | kubectl --context "$CTX" -n "$NS" apply -f - >/dev/null
import sys, pathlib
name, conc, duration, metrics = sys.argv[1:5]
y = pathlib.Path("jobs/agentx.yaml").read_text()
y = y.replace("name: agentx\n", f"name: agentx-{name}\n", 1)
y = y.replace('value: "/artifacts/agentx/PLACEHOLDER"', f'value: "/artifacts/agentx/{name}"')
y = y.replace('{name: CONC, value: "1"}', f'{{name: CONC, value: "{conc}"}}')
y = y.replace('{name: DURATION, value: "300"}', f'{{name: DURATION, value: "{duration}"}}')
y = y.replace('{name: SERVER_METRICS_URLS, value: ""}',
              f'{{name: SERVER_METRICS_URLS, value: "{metrics}"}}')
print(y)
PY
echo "[submit] agentx-$NAME (conc=$CONC duration=${DURATION}s) -> /artifacts/agentx/$NAME"
echo "[submit] follow: kubectl --context $CTX -n $NS logs -f job/agentx-$NAME"

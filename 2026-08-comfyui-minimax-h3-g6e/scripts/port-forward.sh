#!/usr/bin/env bash
# port-forward.sh — open the ComfyUI Web UI locally over kubectl port-forward.
#
# ComfyUI has no auth and a Web-UI code-execution surface, so it is NEVER exposed publicly;
# this is the only access path. Leave this running, then open http://localhost:8188 in a
# browser, or point scripts/run_smoke.py at it (its default --server is this URL).
#
# Usage:
#   ./port-forward.sh                 # namespace comfyui, local port 8188
#   NAMESPACE=comfyui PORT=8188 ./port-forward.sh
set -euo pipefail

NAMESPACE="${NAMESPACE:-comfyui}"
PORT="${PORT:-8188}"
SVC="${SVC:-comfyui}"

echo "kubectl context: $(kubectl config current-context)"
echo "Forwarding svc/${SVC} in ns/${NAMESPACE} to http://localhost:${PORT}"
echo "Open http://localhost:${PORT} in a browser, or run scripts/run_smoke.py. Ctrl-C to stop."
exec kubectl -n "${NAMESPACE}" port-forward "svc/${SVC}" "${PORT}:8188"

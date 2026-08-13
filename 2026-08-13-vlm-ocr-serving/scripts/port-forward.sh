#!/usr/bin/env bash
# port-forward.sh — open one OCR/doc-VLM engine's /extract endpoint locally.
#
# The engines have no auth, so they are ClusterIP only and reached over port-forward, never
# a public endpoint. Leave this running, then POST an image to http://localhost:8000/extract
# (scripts/run_smoke.py --url http://localhost:8000).
#
# Usage:
#   ./port-forward.sh tesseract                 # ns ocr-serving, local 8000
#   NAMESPACE=ocr-serving PORT=8000 ./port-forward.sh paddleocr
set -euo pipefail

SVC="${1:-tesseract}"
NAMESPACE="${NAMESPACE:-ocr-serving}"
PORT="${PORT:-8000}"

echo "kubectl context: $(kubectl config current-context)"
echo "Forwarding svc/${SVC} in ns/${NAMESPACE} to http://localhost:${PORT}"
echo "POST an image:  curl -F image=@receipt.png http://localhost:${PORT}/extract   (Ctrl-C to stop)"
exec kubectl -n "${NAMESPACE}" port-forward "svc/${SVC}" "${PORT}:8000"

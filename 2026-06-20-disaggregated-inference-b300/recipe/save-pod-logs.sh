#!/usr/bin/env bash
# 指定ラベルの pod ログをファイル化して S3 に保存。
# Usage: ./recipe/save-pod-logs.sh <label-selector> <s3-subpath>
# 例:    ./recipe/save-pod-logs.sh app=qwen3-disagg qwen3-8b/logs
set -euo pipefail
SEL="${1:?label selector}"; S3_SUB="${2:?s3 subpath}"
BUCKET="${BUCKET:-akazawt-disagg-b300-776010787911}"
PROFILE="${AWS_PROFILE:-default}"; REGION="${REGION:-us-west-2}"; NS="${NAMESPACE:-akazawt-disagg}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
for p in $(kubectl -n "$NS" get pods -l "$SEL" -o jsonpath='{.items[*].metadata.name}'); do
  echo "==> logs $p"
  kubectl -n "$NS" logs "$p" --all-containers --timestamps > "$TMP/${p}.log" 2>&1 || true
done
aws s3 sync "$TMP" "s3://${BUCKET}/${S3_SUB}/" --profile "$PROFILE" --region "$REGION"
echo "==> saved to s3://${BUCKET}/${S3_SUB}/"

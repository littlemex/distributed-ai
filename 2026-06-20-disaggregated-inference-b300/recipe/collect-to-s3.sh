#!/usr/bin/env bash
# 計測データ/ログを S3 に確実に保存する collector。
#
# 背景: クラスタ node role (別アカ 012345678902) には自アカウント (012345678901)
# S3 への権限が無く、pod から直接 S3 push は AccessDenied になる。よって
#   pod 内 → kubectl cp でローカルへ → ローカルの自分の認証で S3 push
# の経路を使う(node role の S3 権限に非依存)。
#
# Usage:
#   ./recipe/collect-to-s3.sh <pod> <container> <pod-path> <s3-subpath>
# 例:
#   ./recipe/collect-to-s3.sh benchcli cli /results qwen3-8b/goodput
#
# 環境:
#   BUCKET (default: myuser-disagg-b300-012345678901)
#   AWS_PROFILE (default: default), REGION (default: us-west-2), NAMESPACE (default: myuser-disagg)
set -euo pipefail

POD="${1:?pod name}"; CONTAINER="${2:?container}"; POD_PATH="${3:?pod path}"; S3_SUB="${4:?s3 subpath}"
BUCKET="${BUCKET:-myuser-disagg-b300-012345678901}"
PROFILE="${AWS_PROFILE:-default}"; REGION="${REGION:-us-west-2}"; NS="${NAMESPACE:-myuser-disagg}"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
LOCAL="$TMP/$(basename "$POD_PATH")"

echo "==> kubectl cp ${NS}/${POD}:${POD_PATH} -> ${LOCAL}"
kubectl -n "$NS" cp "${POD}:${POD_PATH}" "$LOCAL" -c "$CONTAINER"

echo "==> aws s3 sync ${LOCAL} -> s3://${BUCKET}/${S3_SUB}/"
aws s3 sync "$LOCAL" "s3://${BUCKET}/${S3_SUB}/" --profile "$PROFILE" --region "$REGION"

echo "==> done. listing:"
aws s3 ls "s3://${BUCKET}/${S3_SUB}/" --recursive --profile "$PROFILE" --region "$REGION" | tail -20

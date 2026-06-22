#!/usr/bin/env bash
# EPP の scheduling profile を差し替えて rollout restart する。
# RR / affinity / full の 3 条件を「同じ 8 Pod・同じ EPP 経路」で切り替えるための唯一の操作。
#
# 使い方:
#   ./switch_profile.sh rr        # epp-configs/profile-rr.yaml を適用
#   ./switch_profile.sh affinity
#   ./switch_profile.sh full
set -euo pipefail

PROFILE="${1:?usage: switch_profile.sh <rr|affinity|full>}"
NS=mt-serving
SRC="$(dirname "$0")/epp-configs/profile-${PROFILE}.yaml"

[ -f "$SRC" ] || { echo "[ERR] profile not found: $SRC"; exit 1; }

echo "[INFO] applying profile '${PROFILE}' as ConfigMap mt-lora-epp-config (key profile.yaml)"
kubectl create configmap mt-lora-epp-config -n "$NS" \
  --from-file=profile.yaml="$SRC" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "[INFO] rollout restart EPP"
kubectl rollout restart deploy/mt-lora-epp -n "$NS"
kubectl rollout status deploy/mt-lora-epp -n "$NS" --timeout=180s

echo "[OK] EPP now running profile '${PROFILE}'"
kubectl get pods -n "$NS" -l inferencepool=mt-lora-epp -o wide

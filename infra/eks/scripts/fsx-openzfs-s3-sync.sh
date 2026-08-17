#!/usr/bin/env bash
# One-shot FSx for OpenZFS -> S3 cold-data offload.
# Mounts an existing PVC into a short-lived Pod and runs `aws s3 sync` to S3, then cleans up.
# The Pod's ServiceAccount needs s3:PutObject on the destination (Pod Identity or node role).
#
# Usage:
#   ./scripts/fsx-openzfs-s3-sync.sh --namespace <ns> --pvc <pvc> --bucket <bucket> --prefix <prefix/>
set -euo pipefail

NS="" PVC="" BUCKET="" PREFIX="" SA="fsx-openzfs-s3-backup" IMAGE="public.ecr.aws/aws-cli/aws-cli:latest"
while [ $# -gt 0 ]; do
  case "$1" in
    --namespace) NS="$2"; shift 2 ;;
    --pvc)       PVC="$2"; shift 2 ;;
    --bucket)    BUCKET="$2"; shift 2 ;;
    --prefix)    PREFIX="$2"; shift 2 ;;
    --service-account) SA="$2"; shift 2 ;;
    --image)     IMAGE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$NS" ] && [ -n "$PVC" ] && [ -n "$BUCKET" ] || {
  echo "required: --namespace --pvc --bucket [--prefix <p/>] [--service-account <sa>]" >&2; exit 2; }

POD="fsx-openzfs-s3-sync-$$"
DEST="s3://${BUCKET}/${PREFIX}"
echo "[sync] ns=$NS pvc=$PVC -> $DEST (sa=$SA)"

kubectl run "$POD" -n "$NS" --restart=Never --image="$IMAGE" \
  --overrides="{\"spec\":{\"serviceAccountName\":\"$SA\",\"containers\":[{\"name\":\"sync\",\"image\":\"$IMAGE\",\"command\":[\"aws\",\"s3\",\"sync\",\"/shared\",\"$DEST\"],\"volumeMounts\":[{\"name\":\"vol\",\"mountPath\":\"/shared\"}]}],\"volumes\":[{\"name\":\"vol\",\"persistentVolumeClaim\":{\"claimName\":\"$PVC\"}}]}}"

trap 'kubectl delete pod "$POD" -n "$NS" --ignore-not-found >/dev/null 2>&1 || true' EXIT
if kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/"$POD" -n "$NS" --timeout=600s; then
  echo "[sync] result:"; kubectl logs "$POD" -n "$NS"
  echo "[sync] done"
else
  echo "[sync] FAILED -- pod did not reach Succeeded. logs:" >&2
  kubectl logs "$POD" -n "$NS" 2>&1 || true
  echo "[sync] describe (tail):" >&2
  kubectl describe pod "$POD" -n "$NS" 2>&1 | tail -30 || true
  exit 1
fi

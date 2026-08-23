#!/usr/bin/env bash
# Populate the S3 Files model cache with a Hugging Face checkpoint, by running the transfer as a
# Job INSIDE the cluster.
#
#   ./storage/sync-checkpoint.sh <hf-repo-id> [--yes]
#   ./storage/sync-checkpoint.sh deepseek-ai/DeepSeek-V4-Flash-0731
#
# Why in-cluster and not on a laptop: DeepSeek-V4-Flash is ~160 GB. Pulling that to a workstation
# and pushing it back wastes hours on the slow leg of the path twice over, when a pod in the same
# region as the bucket does it at VPC speed. It is also the only way the transfer survives a closed
# laptop lid.
#
# Why writes go through the S3 API and not through the mount: the S3 Files mount is read-only at
# the node by design (infra/eks/charts/s3files-lib pins `-o ro`), so producers write to the bucket
# and consumers read the file system. S3 Files syncs the two.
#
# Disk discipline: the Job streams FILE BY FILE -- download one, upload it, delete it -- so its
# ephemeral storage stays in the low GB no matter how large the checkpoint is. A naive
# "download the repo, then sync the directory" needs 160 GB of scratch and fails on most nodes.
set -euo pipefail
export AWS_PAGER=""

HERE="$(cd "$(dirname "$0")/.." && pwd)"; cd "$HERE"

REPO="${1:?usage: sync-checkpoint.sh <hf-repo-id> [--yes] [--exclude PATTERNS]}"; shift || true
ASSUME_YES=0
# Default exclusions: alternate-runtime copies of the whole model that FreeToken never reads.
# `metal/` is gpt-oss's 13.75 GB Apple Metal build; `original/` is the common name for a
# pre-conversion copy. NOTHING that FreeToken needs matches these -- in particular `inference/`,
# which DeepSeek-V4 requires, is deliberately NOT excluded.
EXCLUDE="${FT_EXCLUDE:-metal/*,original/*}"
while [ $# -gt 0 ]; do case "$1" in
  --yes) ASSUME_YES=1; shift;;
  --exclude) EXCLUDE="${2:?}"; shift 2;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done

NS="${FT_NAMESPACE:-freetoken}"
CTX="${FT_KUBE_CONTEXT:-$(kubectl config current-context)}"
# AWS_PROFILE is honoured by the CLI directly from the environment, so there is no --profile
# plumbing here. An array-based one would also break under `set -u` on bash 3.2/4.3, where
# expanding an EMPTY array is an unbound-variable error (macOS still ships bash 3.2).

log(){ printf '\n\033[1;32m[sync]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[sync][FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

CTX_CLUSTER="$(kubectl config view -o jsonpath="{.contexts[?(@.name=='$CTX')].context.cluster}" 2>/dev/null || true)"
REGION="$(printf '%s' "$CTX_CLUSTER" | sed -n 's#^arn:aws:eks:\([^:]*\):.*#\1#p')"
CLUSTER="$(printf '%s' "$CTX_CLUSTER" | sed 's#.*/##')"
[ -n "$REGION" ] || die "context '$CTX' is not an EKS ARN"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
AWSR=(aws --region "$REGION")
BUCKET="${FT_BUCKET:-${CLUSTER}-freetoken-models-${ACCOUNT}}"
SA=freetoken-sync
ROLE="${CLUSTER}-freetoken-sync"
JOB="ft-sync-$(printf '%s' "$REPO" | tr 'A-Z/._' 'a-z---' | cut -c1-40 | sed 's/-*$//')"

"${AWSR[@]}" s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1 || die "bucket $BUCKET not found; run storage/setup-s3files.sh first"

echo "  repo   : $REPO"
echo "  exclude: ${EXCLUDE:-(none)}"
echo "  bucket : s3://$BUCKET/$REPO"
echo "  cluster: $CLUSTER ($REGION)  namespace: $NS"
[ "$ASSUME_YES" = 1 ] || { read -r -p "Start the transfer Job? [y/N] " a; [ "$a" = y ] || [ "$a" = Y ] || die "aborted by user"; }

# --- writer IAM: least privilege, this prefix only ----------------------------------------------
if ! "${AWSR[@]}" iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  log "creating role $ROLE"
  "${AWSR[@]}" iam create-role --role-name "$ROLE" --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"pods.eks.amazonaws.com"},"Action":["sts:AssumeRole","sts:TagSession"]}]}' >/dev/null
fi
"${AWSR[@]}" iam put-role-policy --role-name "$ROLE" --policy-name write-model-cache --policy-document \
  "{\"Version\":\"2012-10-17\",\"Statement\":[
     {\"Effect\":\"Allow\",\"Action\":[\"s3:ListBucket\"],\"Resource\":\"arn:aws:s3:::${BUCKET}\"},
     {\"Effect\":\"Allow\",\"Action\":[\"s3:PutObject\",\"s3:GetObject\",\"s3:AbortMultipartUpload\"],\"Resource\":\"arn:aws:s3:::${BUCKET}/*\"}]}" >/dev/null

kubectl --context "$CTX" create namespace "$NS" --dry-run=client -o yaml | kubectl --context "$CTX" apply -f - >/dev/null
kubectl --context "$CTX" -n "$NS" create sa "$SA" --dry-run=client -o yaml | kubectl --context "$CTX" apply -f - >/dev/null
if [ -z "$("${AWSR[@]}" eks list-pod-identity-associations --cluster-name "$CLUSTER" \
      --query "associations[?serviceAccount=='$SA' && namespace=='$NS'].associationId" --output text 2>/dev/null | grep -v '^None$' || true)" ]; then
  "${AWSR[@]}" eks create-pod-identity-association --cluster-name "$CLUSTER" --namespace "$NS" \
    --service-account "$SA" --role-arn "arn:aws:iam::${ACCOUNT}:role/${ROLE}" >/dev/null
fi

# --- the streaming transfer ---------------------------------------------------------------------
kubectl --context "$CTX" -n "$NS" delete job "$JOB" --ignore-not-found >/dev/null 2>&1 || true
kubectl --context "$CTX" -n "$NS" create configmap "$JOB-src" --from-file=sync.py=storage/sync_checkpoint.py \
  --dry-run=client -o yaml | kubectl --context "$CTX" apply -f - >/dev/null

kubectl --context "$CTX" apply -f - <<YAML >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB
  namespace: $NS
spec:
  backoffLimit: 3
  template:
    spec:
      serviceAccountName: $SA
      restartPolicy: OnFailure
      containers:
        - name: sync
          image: public.ecr.aws/docker/library/python:3.12-slim
          command: ["/bin/sh","-c"]
          args:
            - |
              set -eu
              pip install --quiet --no-cache-dir huggingface_hub boto3
              exec python /src/sync.py
          env:
            - name: HF_REPO
              value: "$REPO"
            - name: S3_BUCKET
              value: "$BUCKET"
            - name: AWS_REGION
              value: "$REGION"
            - name: HF_HOME
              value: /scratch/hf
            - name: HF_EXCLUDE
              value: "$EXCLUDE"
          volumeMounts:
            - { name: src, mountPath: /src }
            - { name: scratch, mountPath: /scratch }
          resources:
            requests: { cpu: "2", memory: 4Gi, ephemeral-storage: 30Gi }
            limits:   { memory: 8Gi, ephemeral-storage: 60Gi }
      volumes:
        - name: src
          configMap: { name: $JOB-src }
        # Bounded because the Job streams one file at a time. Sized for the largest single shard
        # plus slack, NOT for the whole checkpoint.
        - name: scratch
          emptyDir: { sizeLimit: 60Gi }
YAML

log "Job $JOB started. Follow it with:"
echo "  kubectl --context $CTX -n $NS logs -f job/$JOB"

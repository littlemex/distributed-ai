#!/usr/bin/env bash
# Create a SELF-CONTAINED S3 Files model cache and wire it into an EXISTING EKS cluster, so
# FreeToken pods read a multi-hundred-GB checkpoint in place instead of each downloading its own.
#
#   ./storage/setup-s3files.sh [--yes] [--bucket NAME] [--prefix PREFIX]
#   ./storage/setup-s3files.sh --add-zone <az> [--yes]   # extra mount target for another AZ
#   ./storage/setup-s3files.sh --down [--yes]
#
# WHY NOT TERRAFORM: infra/eks/s3files-mount.tf and infra/data-layer/s3files.tf already model this
# properly and are the right long-term home. They are deliberately NOT used here for two reasons:
# (1) this reference must not mutate the shared cluster's Terraform configuration, and (2) the
# data-layer file system is scoped to the profiler TRACE bucket, which is a different dataset with
# a different lifecycle from a model cache. So this script builds a parallel, disposable stack.
#
# DRIFT: every resource created here is NEW except two attachments on the cluster's existing EFS
# CSI controller role. Terraform attaches its policies with aws_iam_role_policy_attachment, which
# is non-exclusive, so extra attachments persist and do not show up as drift. The one thing that
# WOULD collide is the efs-csi-node-sa Pod Identity association: if infra/eks is ever applied with
# s3files_enabled=true it will try to create the same association. Delete this stack first in that
# case (--down).
#
# BLAST RADIUS on a shared cluster: giving efs-csi-node-sa a Pod Identity changes the credential
# the NODE plugin uses for ALL of its work, EFS included. That is why the node role below carries
# AmazonEFSCSIDriverPolicy alongside the S3 Files permissions -- without it, enabling S3 Files
# would break every existing EFS mount with `access denied by server`. The DaemonSet must also be
# restarted, because Pod Identity credentials are injected at pod-create time.
set -euo pipefail
export AWS_PAGER=""

HERE="$(cd "$(dirname "$0")/.." && pwd)"; cd "$HERE"

ASSUME_YES=0; DOWN=0; ADD_ZONE=""
BUCKET="${FT_BUCKET:-}"; PREFIX="${FT_PREFIX:-}"
NS="${FT_NAMESPACE:-freetoken}"
CTX="${FT_KUBE_CONTEXT:-$(kubectl config current-context)}"
# AWS_PROFILE is honoured by the CLI directly from the environment, so there is no --profile
# plumbing here. An array-based one would also break under `set -u` on bash 3.2/4.3, where
# expanding an EMPTY array is an unbound-variable error (macOS still ships bash 3.2).

while [ $# -gt 0 ]; do case "$1" in
  --yes) ASSUME_YES=1; shift;;
  --down) DOWN=1; shift;;
  --bucket) BUCKET="${2:?}"; shift 2;;
  --prefix) PREFIX="${2:?}"; shift 2;;
  --add-zone) ADD_ZONE="${2:?}"; shift 2;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done

log(){ printf '\n\033[1;32m[s3files]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[s3files][warn]\033[0m %s\n' "$*" >&2; }
die(){ printf '\033[1;31m[s3files][FAIL]\033[0m %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }
need aws; need kubectl; need python3
TMPERR="$(mktemp)"; trap 'rm -f "$TMPERR"' EXIT

# The context's cluster entry is an EKS ARN; derive region + cluster name so neither needs an env
# var and neither can silently disagree with the kubeconfig we are about to mutate.
CTX_CLUSTER="$(kubectl config view -o jsonpath="{.contexts[?(@.name=='$CTX')].context.cluster}" 2>/dev/null || true)"
case "$CTX_CLUSTER" in
  arn:aws:eks:*) : ;;
  *) die "context '$CTX' does not map to an EKS ARN (got '$CTX_CLUSTER'); set FT_KUBE_CONTEXT";;
esac
REGION="$(printf '%s' "$CTX_CLUSTER" | sed -n 's#^arn:aws:eks:\([^:]*\):.*#\1#p')"
CLUSTER="$(printf '%s' "$CTX_CLUSTER" | sed 's#.*/##')"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
AWSR=(aws --region "$REGION")

BUCKET="${BUCKET:-${CLUSTER}-freetoken-models-${ACCOUNT}}"
FS_ROLE="${CLUSTER}-s3files-model-cache"
NODE_ROLE="${CLUSTER}-efs-csi-node-s3files"
MT_SG_NAME="${CLUSTER}-s3files-model-cache-mt"

# --- extra mount target for another AZ ----------------------------------------------------------
# One mount target means one AZ, because the NFS endpoint resolves per-AZ and the PV's nodeAffinity
# pins every consumer there. That is fine until the instance type you need is not offered in that
# AZ -- exactly what happens with g7e (us-east-2a/2b only) against a mount target in us-east-2c.
# S3 Files allows several mount targets, so add one and bind a SECOND PV/PVC pinned to the new AZ;
# the file system and its data are shared, only the network path differs.
if [ -n "$ADD_ZONE" ]; then
  FS_ID="$("${AWSR[@]}" s3files list-file-systems --query "fileSystems[?bucket=='arn:aws:s3:::${BUCKET}'].fileSystemId" --output text 2>/dev/null || true)"
  { [ -n "$FS_ID" ] && [ "$FS_ID" != None ]; } || die "no S3 Files file system for bucket $BUCKET; run without --add-zone first"
  AP_ID="$("${AWSR[@]}" s3files list-access-points --file-system-id "$FS_ID" --query 'accessPoints[0].accessPointId' --output text 2>/dev/null || true)"
  { [ -n "$AP_ID" ] && [ "$AP_ID" != None ]; } || die "file system $FS_ID has no access point"
  VPC_ID="$("${AWSR[@]}" eks describe-cluster --name "$CLUSTER" --query 'cluster.resourcesVpcConfig.vpcId' --output text)"
  SUBNET=""
  while IFS=$'\t' read -r sid saz; do
    [ "$saz" = "$ADD_ZONE" ] && { SUBNET="$sid"; break; }
  done < <("${AWSR[@]}" ec2 describe-subnets \
      --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:karpenter.sh/discovery,Values=$CLUSTER" \
      --query 'Subnets[].[SubnetId,AvailabilityZone]' --output text)
  [ -n "$SUBNET" ] || die "no cluster subnet tagged karpenter.sh/discovery=$CLUSTER in $ADD_ZONE"
  MT_SG="$("${AWSR[@]}" ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" \
    "Name=group-name,Values=$MT_SG_NAME" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"
  { [ -n "$MT_SG" ] && [ "$MT_SG" != None ]; } || die "mount-target SG $MT_SG_NAME not found; run without --add-zone first"

  if "${AWSR[@]}" s3files list-mount-targets --file-system-id "$FS_ID" \
       --query "mountTargets[?subnetId=='$SUBNET'].mountTargetId" --output text 2>/dev/null | grep -q .; then
    log "a mount target already exists in $ADD_ZONE"
  else
    log "creating a mount target in $SUBNET ($ADD_ZONE)"
    "${AWSR[@]}" s3files create-mount-target --file-system-id "$FS_ID" \
      --subnet-id "$SUBNET" --security-groups "$MT_SG" >/dev/null
  fi
  cat <<DONE

$(log "ready in $ADD_ZONE")
  volumeHandle : s3files:${FS_ID}::${AP_ID}
  zone         : ${ADD_ZONE}

Bind a SECOND PV/PVC for this AZ (a distinct release name; the PV name must differ because a PV is
cluster-scoped and its nodeAffinity is what pins the AZ):
  helm upgrade --install freetoken-model-cache-${ADD_ZONE} storage/model-cache \\
    --set name=freetoken-model-cache-${ADD_ZONE} \\
    --set volumeHandle="s3files:${FS_ID}::${AP_ID}" --set zone="${ADD_ZONE}" --set namespace="${NS}"
DONE
  exit 0
fi

# --- teardown -----------------------------------------------------------------------------------
if [ "$DOWN" = 1 ]; then
  [ "$ASSUME_YES" = 1 ] || { read -r -p "Tear down the S3 Files model cache in $CLUSTER/$REGION? [y/N] " a; [ "$a" = y ] || die aborted; }
  log "removing the Pod Identity association for efs-csi-node-sa"
  id="$("${AWSR[@]}" eks list-pod-identity-associations --cluster-name "$CLUSTER" \
        --query "associations[?serviceAccount=='efs-csi-node-sa' && namespace=='kube-system'].associationId" --output text 2>/dev/null || true)"
  if [ -n "$id" ] && [ "$id" != None ]; then
    "${AWSR[@]}" eks delete-pod-identity-association --cluster-name "$CLUSTER" --association-id "$id" >/dev/null || true
    warn "restart the node plugin so it stops using the deleted credential: kubectl -n kube-system rollout restart ds/efs-csi-node"
  fi
  # ORDER MATTERS: the mount target must go before the file system -- an EFS-backed fs cannot be
  # deleted while a mount target exists, and deleting the access point first would cut I/O on any
  # live pod and then fail on the fs, leaving a half-torn-down, service-down state.
  fs="$("${AWSR[@]}" s3files list-file-systems --query "fileSystems[?bucket=='arn:aws:s3:::${BUCKET}'].fileSystemId" --output text 2>/dev/null || true)"
  if [ -n "$fs" ] && [ "$fs" != None ]; then
    for mt in $("${AWSR[@]}" s3files list-mount-targets --file-system-id "$fs" --query 'mountTargets[].mountTargetId' --output text 2>/dev/null || true); do
      log "deleting mount target $mt"; "${AWSR[@]}" s3files delete-mount-target --mount-target-id "$mt" >/dev/null || true
    done
    for ap in $("${AWSR[@]}" s3files list-access-points --file-system-id "$fs" --query 'accessPoints[].accessPointId' --output text 2>/dev/null || true); do
      log "deleting access point $ap"; "${AWSR[@]}" s3files delete-access-point --access-point-id "$ap" >/dev/null || true
    done
    log "deleting file system $fs (mount targets take a few minutes to clear first)"
    "${AWSR[@]}" s3files delete-file-system --file-system-id "$fs" >/dev/null || warn "fs delete failed; retry once the mount targets are gone"
  fi
  log "kept the S3 bucket $BUCKET (it holds the checkpoints). Remove it manually when done."
  exit 0
fi

# --- plan ---------------------------------------------------------------------------------------
cat <<PLAN

  cluster   : $CLUSTER ($REGION), account $ACCOUNT
  bucket    : $BUCKET${PREFIX:+  prefix: $PREFIX}
  namespace : $NS
  will create: S3 bucket (versioned) + S3 Files fs + access point + mount target + SG
  will MODIFY the shared cluster:
    - attach S3 Files client policies to the existing EFS CSI controller role (additive)
    - create $NODE_ROLE and a Pod Identity association for kube-system/efs-csi-node-sa
    - restart ds/efs-csi-node (Pod Identity is injected at pod-create time)

PLAN
[ "$ASSUME_YES" = 1 ] || { read -r -p "Proceed? [y/N] " a; [ "$a" = y ] || [ "$a" = Y ] || die "aborted by user"; }

# --- 1. bucket ----------------------------------------------------------------------------------
# S3 Files requires bucket VERSIONING, and supports only SSE-S3 or SSE-KMS.
if "${AWSR[@]}" s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  log "bucket $BUCKET already exists"
else
  log "creating bucket $BUCKET"
  if [ "$REGION" = us-east-1 ]; then
    "${AWSR[@]}" s3api create-bucket --bucket "$BUCKET" >/dev/null
  else
    "${AWSR[@]}" s3api create-bucket --bucket "$BUCKET" \
      --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
  fi
fi
"${AWSR[@]}" s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled >/dev/null
"${AWSR[@]}" s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}' >/dev/null
"${AWSR[@]}" s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true' >/dev/null
# S3 Files REQUIRES versioning, so every re-sync of a shard leaves the previous multi-GB version
# billable forever. Expire noncurrent versions and clean up aborted multipart uploads.
"${AWSR[@]}" s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" --lifecycle-configuration '{
  "Rules": [
    {"ID": "expire-noncurrent-checkpoint-versions", "Status": "Enabled", "Filter": {"Prefix": ""},
     "NoncurrentVersionExpiration": {"NoncurrentDays": 7}},
    {"ID": "abort-incomplete-multipart", "Status": "Enabled", "Filter": {"Prefix": ""},
     "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 3}}
  ]}' >/dev/null

# --- 2. the file system's service role ----------------------------------------------------------
# Trusted by elasticfilesystem.amazonaws.com (S3 Files is EFS-backed) with the standard
# confusion-deputy guards so another account cannot induce this role to be assumed on its behalf.
TRUST=$(python3 - "$ACCOUNT" "$REGION" <<'PY'
import json,sys
acct,region=sys.argv[1],sys.argv[2]
print(json.dumps({"Version":"2012-10-17","Statement":[{
 "Effect":"Allow","Principal":{"Service":"elasticfilesystem.amazonaws.com"},
 "Action":"sts:AssumeRole",
 "Condition":{"StringEquals":{"aws:SourceAccount":acct},
              "ArnLike":{"aws:SourceArn":f"arn:aws:s3files:{region}:{acct}:file-system/*"}}}]}))
PY
)
if "${AWSR[@]}" iam get-role --role-name "$FS_ROLE" >/dev/null 2>&1; then
  # RECONCILE the trust policy, do not just note that the role exists. A role created by an earlier
  # run with a wrong trust policy would otherwise never be corrected, and the symptom is remote from
  # the cause: create-file-system SUCCEEDS and the file system then sits in status=error with
  # "S3 Files does not have permissions to assume the provided role" until someone reads it.
  log "role $FS_ROLE exists; reconciling its trust policy"
  "${AWSR[@]}" iam update-assume-role-policy --role-name "$FS_ROLE" --policy-document "$TRUST" >/dev/null \
    || die "failed to update the trust policy on $FS_ROLE"
else
  log "creating role $FS_ROLE"
  "${AWSR[@]}" iam create-role --role-name "$FS_ROLE" --assume-role-policy-document "$TRUST" >/dev/null
fi
FS_POLICY=$(python3 - "$BUCKET" <<'PY'
import json,sys
b=sys.argv[1]
print(json.dumps({"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["s3:ListBucket","s3:GetBucketVersioning","s3:GetBucketLocation"],
  "Resource":f"arn:aws:s3:::{b}"},
 {"Effect":"Allow","Action":["s3:GetObject","s3:GetObjectVersion","s3:PutObject","s3:DeleteObject",
                             "s3:ListBucketVersions","s3:AbortMultipartUpload"],
  "Resource":f"arn:aws:s3:::{b}/*"}]}))
PY
)
"${AWSR[@]}" iam put-role-policy --role-name "$FS_ROLE" --policy-name bucket-access --policy-document "$FS_POLICY" >/dev/null
FS_ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${FS_ROLE}"

# --- 3. the file system -------------------------------------------------------------------------
FS_ID="$("${AWSR[@]}" s3files list-file-systems --query "fileSystems[?bucket=='arn:aws:s3:::${BUCKET}'].fileSystemId" --output text 2>/dev/null || true)"
if [ -n "$FS_ID" ] && [ "$FS_ID" != None ]; then
  log "file system $FS_ID already linked to $BUCKET"
else
  log "creating the S3 Files file system (IAM propagation can make the first attempt fail; retrying)"
  # --prefix scopes the file system to part of the bucket, so one bucket can host several datasets
  # with independent file systems instead of needing a bucket per dataset.
  # The error is CAPTURED, not discarded: hiding it turns an IAM/trust mistake into a mysterious
  # timeout in the wait loop below rather than a message that names the problem.
  FS_ID=""
  for i in 1 2 3 4 5 6; do
    if FS_ID="$("${AWSR[@]}" s3files create-file-system \
          --bucket "arn:aws:s3:::${BUCKET}" ${PREFIX:+--prefix "$PREFIX"} \
          --role-arn "$FS_ROLE_ARN" --accept-bucket-warning \
          --query fileSystemId --output text 2>"$TMPERR")"; then break; fi
    err="$(cat "$TMPERR")"
    [ "$i" = 6 ] && die "create-file-system failed after 6 attempts: $err"
    warn "attempt $i failed (retrying in $((i*10))s): $err"
    sleep $((i*10))
  done
  [ -n "$FS_ID" ] && [ "$FS_ID" != None ] || die "create-file-system returned no file system id"
fi
log "waiting for the file system to become available"
st=""
for _ in $(seq 1 60); do
  st="$("${AWSR[@]}" s3files get-file-system --file-system-id "$FS_ID" --query status --output text 2>/dev/null || echo pending)"
  [ "$st" = available ] && break
  # A trust-policy mistake surfaces HERE, as status=error with an explanatory statusMessage, not as
  # an API failure at create time. Fail immediately and quote it rather than spinning for 10 min.
  if [ "$st" = error ]; then
    msg="$("${AWSR[@]}" s3files get-file-system --file-system-id "$FS_ID" --query statusMessage --output text 2>/dev/null || true)"
    die "file system $FS_ID entered status=error: $msg"
  fi
  sleep 10
done
[ "$st" = available ] || die "file system $FS_ID did not become available (status: ${st:-unknown})"

# --- 4. access point (MANDATORY) ----------------------------------------------------------------
# The EFS CSI driver cannot mount an S3 Files file system by fs id alone; the volumeHandle needs
# an access point id.
AP_ID="$("${AWSR[@]}" s3files list-access-points --file-system-id "$FS_ID" --query 'accessPoints[0].accessPointId' --output text 2>/dev/null || true)"
if [ -z "$AP_ID" ] || [ "$AP_ID" = None ]; then
  log "creating an access point"
  AP_ID="$("${AWSR[@]}" s3files create-access-point --file-system-id "$FS_ID" --query accessPointId --output text)"
fi

# --- 5. mount target in the cluster VPC ---------------------------------------------------------
VPC_ID="$("${AWSR[@]}" eks describe-cluster --name "$CLUSTER" --query 'cluster.resourcesVpcConfig.vpcId' --output text)"

# The NFS ingress source must be the SGs the NODES actually carry, which on a Karpenter cluster is
# NOT the cluster security group: the EC2NodeClass attaches whatever is tagged
# karpenter.sh/discovery=<cluster>, and verified on this cluster the Karpenter nodes carry only
# those, with the cluster SG absent. Authorizing the cluster SG alone therefore produces a mount
# that hangs rather than fails -- the pod sits in ContainerCreating until the NFS timeout. Collect
# every plausible node SG (Karpenter-discovered + the cluster SG, which managed nodegroups do use)
# and authorize each.
NODE_SGS="$("${AWSR[@]}" ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:karpenter.sh/discovery,Values=$CLUSTER" \
  --query 'SecurityGroups[].GroupId' --output text)"
CLUSTER_SG="$("${AWSR[@]}" eks describe-cluster --name "$CLUSTER" --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)"
NODE_SGS="$(printf '%s %s' "$NODE_SGS" "$CLUSTER_SG" | tr '\t' ' ' | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')"
[ -n "$(printf '%s' "$NODE_SGS" | tr -d ' ')" ] || die "found no node security groups to authorize for NFS"
log "NFS ingress will be allowed from: $NODE_SGS"
# AZ choice is consequential and is NOT arbitrary: there is one mount target, its NFS endpoint
# resolves only from its own AZ, and the PV's nodeAffinity therefore pins EVERY consumer -- serving
# pods and agent pods alike -- into that AZ. Picking an AZ that cannot offer the GPU size the model
# needs produces a pod that waits forever for capacity that will never appear there. So prefer an AZ
# that offers the largest g6e size this reference uses, and let the operator override.
G6E_NEEDED="${FT_G6E_TYPE:-g6e.8xlarge}"
# Plain while-read rather than mapfile: mapfile is bash 4+, and macOS still ships bash 3.2 as
# /bin/bash, so this script would break for anyone without a newer bash on PATH.
SUBNETS=""
while IFS=$'\t' read -r _sid _saz; do
  [ -n "$_sid" ] && SUBNETS="${SUBNETS}${_sid} ${_saz}"$'\n'
done < <("${AWSR[@]}" ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:karpenter.sh/discovery,Values=$CLUSTER" \
  --query 'Subnets[].[SubnetId,AvailabilityZone]' --output text)
[ -n "$SUBNETS" ] || die "no subnet tagged karpenter.sh/discovery=$CLUSTER in $VPC_ID"

# `--output text` emits TAB-separated values; the space-delimited `case` match below would never
# fire against tabs, making every AZ look like it lacks GPU capacity. Normalize to spaces.
GPU_AZS="$("${AWSR[@]}" ec2 describe-instance-type-offerings --location-type availability-zone \
  --filters "Name=instance-type,Values=$G6E_NEEDED" --query 'InstanceTypeOfferings[].Location' \
  --output text | tr '\t' ' ' | tr -s ' ')"

SUBNET=""; MT_AZ=""; FIRST_SUBNET=""; FIRST_AZ=""
while read -r sid saz; do
  [ -n "$sid" ] || continue
  [ -n "$FIRST_SUBNET" ] || { FIRST_SUBNET="$sid"; FIRST_AZ="$saz"; }
  if [ -n "${FT_ZONE:-}" ]; then
    [ "$saz" = "$FT_ZONE" ] && { SUBNET="$sid"; MT_AZ="$saz"; break; }
  else
    case " $GPU_AZS " in *" $saz "*) SUBNET="$sid"; MT_AZ="$saz"; break;; esac
  fi
done <<EOF
$SUBNETS
EOF

if [ -z "$SUBNET" ]; then
  if [ -n "${FT_ZONE:-}" ]; then
    die "FT_ZONE=$FT_ZONE has no cluster subnet tagged karpenter.sh/discovery=$CLUSTER"
  fi
  SUBNET="$FIRST_SUBNET"; MT_AZ="$FIRST_AZ"
  warn "no cluster subnet is in an AZ that offers $G6E_NEEDED; falling back to $MT_AZ. Serving pods pinned there may never get GPU capacity."
fi
log "mount target AZ: $MT_AZ (offers $G6E_NEEDED: $(case " $GPU_AZS " in *" $MT_AZ "*) echo yes;; *) echo NO;; esac))"

MT_SG="$("${AWSR[@]}" ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" \
  "Name=group-name,Values=$MT_SG_NAME" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"
if [ -z "$MT_SG" ] || [ "$MT_SG" = None ]; then
  log "creating mount-target SG $MT_SG_NAME"
  MT_SG="$("${AWSR[@]}" ec2 create-security-group --group-name "$MT_SG_NAME" \
    --description "S3 Files model cache mount target: NFS 2049 from EKS nodes" \
    --vpc-id "$VPC_ID" --query GroupId --output text)"
fi
# Reference the node SGs rather than a CIDR: node IPs churn with Karpenter, SG ids do not.
# InvalidPermission.Duplicate is the idempotent re-run case and is the ONLY error tolerated here --
# swallowing everything would let an AccessDenied pass as success and leave a mount that hangs.
for sg in $NODE_SGS; do
  if err="$("${AWSR[@]}" ec2 authorize-security-group-ingress --group-id "$MT_SG" \
        --ip-permissions "IpProtocol=tcp,FromPort=2049,ToPort=2049,UserIdGroupPairs=[{GroupId=$sg}]" 2>&1 >/dev/null)"; then
    log "authorized NFS 2049 from $sg"
  else
    case "$err" in
      *InvalidPermission.Duplicate*) : ;;
      *) die "failed to authorize NFS 2049 from $sg: $err";;
    esac
  fi
done

EXISTING_MT="$("${AWSR[@]}" s3files list-mount-targets --file-system-id "$FS_ID" \
  --query 'mountTargets[0].mountTargetId' --output text 2>/dev/null | grep -v '^None$' || true)"
if [ -z "$EXISTING_MT" ]; then
  log "creating a mount target in $SUBNET ($MT_AZ)"
  "${AWSR[@]}" s3files create-mount-target --file-system-id "$FS_ID" \
    --subnet-id "$SUBNET" --security-groups "$MT_SG" >/dev/null
else
  # An existing mount target's AZ is authoritative: it is the only AZ whose NFS DNS resolves, so the
  # PV must be pinned there regardless of which AZ the selection logic above would have chosen. On a
  # re-run, reporting the newly-selected AZ instead would pin every pod to an AZ that cannot mount.
  MT_SUBNET="$("${AWSR[@]}" s3files get-mount-target --mount-target-id "$EXISTING_MT" --query subnetId --output text)"
  MT_AZ="$("${AWSR[@]}" ec2 describe-subnets --subnet-ids "$MT_SUBNET" --query 'Subnets[0].AvailabilityZone' --output text)"
  log "reusing mount target $EXISTING_MT in $MT_AZ (its AZ overrides the selection above)"
fi

# --- 6. EFS CSI driver IAM ----------------------------------------------------------------------
# AmazonS3FilesCSIDriverPolicy lives under the service-role/ PATH, not at the top level -- the
# top-level ARN does not exist and AttachRolePolicy rejects it with NoSuchEntity.
S3F_CSI='arn:aws:iam::aws:policy/service-role/AmazonS3FilesCSIDriverPolicy'
# ClientReadOnly, not ClientFullAccess: per the S3 Files docs, s3files:ClientMount WITHOUT
# s3files:ClientWrite yields a mount that is read-only at the NFS layer, enforced on every mount.
# Since the CSI node plugin's credential authorizes every S3 Files mount on the cluster, granting
# only the read-only variant means no pod can obtain a writable mount regardless of what its PV
# asks for -- the read-only intent becomes structural instead of advisory. Producers write to the
# bucket through the S3 API, never through the mount.
S3F_CLIENT='arn:aws:iam::aws:policy/AmazonS3FilesClientReadOnlyAccess'
S3_RO='arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess'
EFS_CSI_POLICY='arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy'

CTRL_ROLE="$("${AWSR[@]}" eks list-pod-identity-associations --cluster-name "$CLUSTER" \
  --query "associations[?serviceAccount=='efs-csi-controller-sa'].associationId" --output text 2>/dev/null || true)"
if [ -n "$CTRL_ROLE" ] && [ "$CTRL_ROLE" != None ]; then
  CTRL_ARN="$("${AWSR[@]}" eks describe-pod-identity-association --cluster-name "$CLUSTER" \
    --association-id "$CTRL_ROLE" --query 'association.roleArn' --output text)"
  CTRL_NAME="${CTRL_ARN##*/}"
  log "granting S3 Files to the existing controller role $CTRL_NAME (additive attachments)"
  for p in "$S3F_CSI" "$S3F_CLIENT"; do
    "${AWSR[@]}" iam attach-role-policy --role-name "$CTRL_NAME" --policy-arn "$p" >/dev/null \
      || die "failed to attach $p to $CTRL_NAME (attach-role-policy is idempotent, so this is a real error)"
  done
else
  warn "no Pod Identity association found for efs-csi-controller-sa; grant $S3F_CSI and $S3F_CLIENT to whatever role the controller uses"
fi

# Node plugin: its own role. Do NOT rely on the node instance role -- a Karpenter + managed
# nodegroup cluster has more than one, and pods on the ungranted one fail with
# `mount.nfs4: access denied by server`.
if ! "${AWSR[@]}" iam get-role --role-name "$NODE_ROLE" >/dev/null 2>&1; then
  log "creating role $NODE_ROLE"
  "${AWSR[@]}" iam create-role --role-name "$NODE_ROLE" --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"pods.eks.amazonaws.com"},"Action":["sts:AssumeRole","sts:TagSession"]}]}' >/dev/null
fi
# AmazonEFSCSIDriverPolicy is NOT optional here: Pod Identity replaces the SA's credential for ALL
# of the node plugin's AWS calls, so without it every EXISTING EFS mount on this cluster would
# start failing with `access denied`. S3ReadOnly is for the high-throughput direct-from-S3 reads
# that make a 160 GB in-place read tolerable.
for p in "$S3F_CLIENT" "$EFS_CSI_POLICY" "$S3_RO"; do
  "${AWSR[@]}" iam attach-role-policy --role-name "$NODE_ROLE" --policy-arn "$p" >/dev/null \
    || die "failed to attach $p to $NODE_ROLE; without all three the node plugin breaks EFS or cannot mount S3 Files"
done
NODE_ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${NODE_ROLE}"

existing="$("${AWSR[@]}" eks list-pod-identity-associations --cluster-name "$CLUSTER" \
  --query "associations[?serviceAccount=='efs-csi-node-sa' && namespace=='kube-system'].associationId" --output text 2>/dev/null || true)"
if [ -z "$existing" ] || [ "$existing" = None ]; then
  log "associating kube-system/efs-csi-node-sa with $NODE_ROLE"
  "${AWSR[@]}" eks create-pod-identity-association --cluster-name "$CLUSTER" \
    --namespace kube-system --service-account efs-csi-node-sa --role-arn "$NODE_ROLE_ARN" >/dev/null
  # Credentials are injected by a mutating webhook at pod-create time, so already-running
  # DaemonSet pods keep using the node instance role until restarted.
  log "restarting ds/efs-csi-node to pick up the credential"
  kubectl --context "$CTX" -n kube-system rollout restart ds/efs-csi-node >/dev/null
  kubectl --context "$CTX" -n kube-system rollout status ds/efs-csi-node --timeout=5m || warn "node plugin rollout did not settle; check it before mounting"
else
  cur="$("${AWSR[@]}" eks describe-pod-identity-association --cluster-name "$CLUSTER" --association-id "$existing" --query 'association.roleArn' --output text)"
  [ "$cur" = "$NODE_ROLE_ARN" ] && log "efs-csi-node-sa already associated with $NODE_ROLE" \
    || warn "efs-csi-node-sa is associated with $cur, not $NODE_ROLE_ARN; leaving it (delete the association to switch)"
fi

kubectl --context "$CTX" create namespace "$NS" --dry-run=client -o yaml | kubectl --context "$CTX" apply -f - >/dev/null

cat <<DONE

$(log "ready")
  volumeHandle : s3files:${FS_ID}::${AP_ID}
  zone         : ${MT_AZ}
  bucket       : ${BUCKET}${PREFIX:+ (prefix ${PREFIX})}

Bind it into the namespace:
  helm dependency build storage/model-cache
  helm upgrade --install freetoken-model-cache storage/model-cache \\
    --set volumeHandle="s3files:${FS_ID}::${AP_ID}" --set zone="${MT_AZ}" --set namespace="${NS}"

Then populate a checkpoint (writes go through the S3 API; the mount is read-only by design):
  ./storage/sync-checkpoint.sh openai/gpt-oss-20b

NOTE: the mount target is single-AZ (${MT_AZ}). Serving pods are pinned there by the PV's
nodeAffinity, so ${MT_AZ} must have capacity for the g6e size the model needs.
DONE

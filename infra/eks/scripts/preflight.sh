#!/usr/bin/env bash
# preflight.sh -- confirm a cluster provides what accelerated test cases (e.g. the pytorch/miles
# and pytorch/slime GRPO cases) schedule against, so a missing piece surfaces as a NAMED error
# here instead of a silent Pending / ImagePullBackOff / mount failure at run time.
#
# Checks (read-only):
#   1. required CLIs present, and kubectl reachable at the intended cluster
#   2. node-role labels present (the stable placement API; ADR D11 / docs/node-role-separation.md)
#   3. nvidia.com/gpu advertised (NVIDIA device plugin / GPU operator / GPU AMI)
#   4. vpc.amazonaws.com/efa advertised on GPU pools (aws-efa-k8s-device-plugin)
#   5. storage CSI drivers installed and the module's static PVs healthy
#   6. EFA node security group has a self-referencing ALL-TRAFFIC egress rule (silently breaks
#      multi-node NCCL/EFA when missing -- see sg.tf efa_node_egress_self)
#
# Cluster identity and the EFA SG id are read from `terraform output` when run in infra/eks;
# override with env: CLUSTER_NAME, REGION, EFA_SECURITY_GROUP_ID, AWS_PROFILE.
# Usage:  ./scripts/preflight.sh            (from infra/eks, after apply)
#         CLUSTER_NAME=foo REGION=us-east-2 ./scripts/preflight.sh
set -uo pipefail

fail=0; warn=0
red(){ printf '\033[31m[FAIL]\033[0m %s\n' "$*"; fail=$((fail+1)); }
ylw(){ printf '\033[33m[WARN]\033[0m %s\n' "$*"; warn=$((warn+1)); }
grn(){ printf '\033[32m[ OK ]\033[0m %s\n' "$*"; }

for c in kubectl; do command -v "$c" >/dev/null 2>&1 || { echo "[FAIL] required command not found: $c"; exit 1; }; done

tfout(){ command -v terraform >/dev/null 2>&1 && terraform output -raw "$1" 2>/dev/null; }
CLUSTER_NAME="${CLUSTER_NAME:-$(tfout cluster_name)}"
REGION="${REGION:-$(tfout region)}"
EFA_SG="${EFA_SECURITY_GROUP_ID:-$(tfout efa_security_group_id)}"
AWS=(aws); [ -n "${AWS_PROFILE:-}" ] && AWS+=(--profile "$AWS_PROFILE"); [ -n "${REGION:-}" ] && AWS+=(--region "$REGION")

echo "== preflight: cluster='${CLUSTER_NAME:-?}' region='${REGION:-?}' =="

# 1. kubectl reachable
if ! kubectl version -o json >/dev/null 2>&1; then
  red "kubectl cannot reach a cluster. Run: aws eks update-kubeconfig --name ${CLUSTER_NAME:-<cluster>} --region ${REGION:-<region>}"
  echo "== stopping: no cluster =="; exit 1
fi
ctx="$(kubectl config current-context 2>/dev/null)"
grn "kubectl reachable (context: ${ctx})"
[ -n "$CLUSTER_NAME" ] && ! printf '%s' "$ctx" | grep -qF -- "$CLUSTER_NAME" && \
  ylw "context '${ctx}' does not contain '${CLUSTER_NAME}' -- confirm you are on the right cluster"

# 2. node-role labels (distinguish "no nodes returned" from "nodes lack the label")
if ! nodes_json="$(kubectl get nodes -o json 2>/dev/null)"; then
  red "cannot list nodes (RBAC or connectivity) -- cannot check placement labels"
else
  roles="$(printf '%s' "$nodes_json" | python3 -c 'import json,sys;print("\n".join(sorted({n["metadata"].get("labels",{}).get("node-role","") for n in json.load(sys.stdin)["items"]}-{""})))' 2>/dev/null)"
  if [ -z "$roles" ]; then
    red "no node carries a 'node-role' label. Test-case manifests select on node-role by default (GPU_NODE_LABEL_KEY/CPU_NODE_LABEL_KEY); set those to your cluster's real label key/value or pods stay Pending."
  else
    grn "node-role labels present: $(printf '%s' "$roles" | paste -sd' ' -)"
  fi
fi

# 3. nvidia.com/gpu advertised (currently-schedulable total; a scaled-to-zero pool shows 0)
gpu_alloc="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null | awk 'NF{s+=$1} END{print s+0}')"
if [ "${gpu_alloc:-0}" -gt 0 ] 2>/dev/null; then
  grn "nvidia.com/gpu advertised now (total allocatable: ${gpu_alloc})"
else
  ylw "no nvidia.com/gpu allocatable right now (GPU pool may be scaled to 0); ensure the NVIDIA device plugin / GPU operator is installed so it advertises once a GPU node is up"
fi

# 4. vpc.amazonaws.com/efa advertised + device plugin present (report PER-NODE distinct values)
efa_per_node="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.vpc\.amazonaws\.com/efa}{"\n"}{end}' 2>/dev/null | awk 'NF' | sort -u | paste -sd, -)"
efa_ds="$(kubectl get ds -A -o name 2>/dev/null | grep -c efa)"
if [ -n "$efa_per_node" ]; then
  grn "vpc.amazonaws.com/efa advertised; per-node allocatable = ${efa_per_node} -> set EFA_PER_NODE to that"
elif [ "${efa_ds:-0}" -gt 0 ] 2>/dev/null; then
  ylw "EFA device plugin DaemonSet present but no EFA allocatable yet (GPU pool scaled to 0?)"
else
  ylw "no EFA device plugin DaemonSet found. Single-node non-EFA runs must remove the vpc.amazonaws.com/efa requests from raycluster.yaml; multi-node NCCL over EFA requires it"
fi

# 5. storage CSI drivers + module static PVs
for d in fsx.csi.aws.com efs.csi.aws.com ebs.csi.aws.com; do
  kubectl get csidriver "$d" >/dev/null 2>&1 && grn "CSI driver installed: $d" || ylw "CSI driver not found: $d (needed only if a test case uses it)"
done
for pv in fsx-training openzfs-shared; do
  ph="$(kubectl get pv "$pv" -o jsonpath='{.status.phase}' 2>/dev/null)"
  case "$ph" in
    Bound|Available) grn "static PV ${pv}: ${ph}";;
    "")              ylw "static PV ${pv} not found (storage layer may be disabled in tfvars)";;
    Released|Pending) ylw "static PV ${pv} in phase ${ph} (usable after the stale claimRef is cleared / a claim binds)";;
    *)               red "static PV ${pv} in phase ${ph}";;
  esac
done

# 6. EFA SG self-referencing ALL-TRAFFIC egress (an aws error must NOT read as a missing rule)
if [ -z "${EFA_SG:-}" ]; then
  ylw "EFA security group id unknown (run from infra/eks after apply, or set EFA_SECURITY_GROUP_ID) -- skipping the egress check"
elif out="$("${AWS[@]}" ec2 describe-security-groups --group-ids "$EFA_SG" \
        --query "length(SecurityGroups[0].IpPermissionsEgress[?IpProtocol=='-1'] | [?UserIdGroupPairs[?GroupId=='${EFA_SG}']])" \
        --output text 2>&1)"; then
  if [ "${out:-0}" -ge 1 ] 2>/dev/null; then
    grn "EFA SG ${EFA_SG} has a self-referencing all-traffic egress rule (required for EFA SRD / multi-node NCCL)"
  else
    red "EFA SG ${EFA_SG} is MISSING a self-referencing all-traffic (-1) egress rule -- multi-node NCCL over EFA will time out after selecting the efa provider. See sg.tf (efa_node_egress_self)"
  fi
else
  ylw "could not describe ${EFA_SG} (aws cli error: ${out%%$'\n'*}) -- skipping the egress check, not failing on it"
fi

echo "== preflight: ${fail} fail, ${warn} warn =="
[ "$fail" -eq 0 ] || echo "Resolve [FAIL] items before launching accelerated jobs; [WARN] items are situational."
[ "$fail" -eq 0 ]

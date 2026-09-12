#!/usr/bin/env bash
# Create (idempotently) an IAM role the agents assume via EKS Pod Identity to call Amazon Bedrock's
# server-side web_search. deploy.sh --websearch calls this when QWEN_BEDROCK_ROLE_ARN is unset; it
# also runs standalone. The ONLY thing printed to stdout is the role ARN, so it can be captured
# directly:  QWEN_BEDROCK_ROLE_ARN="$(scripts/setup-websearch-role.sh)".
#
# Trust: pods.eks.amazonaws.com (Pod Identity). Permissions: the AWS-managed AmazonBedrockFullAccess.
# The bedrock-mantle web_search API needs more than bedrock:InvokeModel (a bedrock:*-only inline
# policy is rejected with HTTP 401), so this attaches the same managed policy the validated setup
# uses. Override the name with QWEN_WEBSEARCH_ROLE_NAME. Needs iam:GetRole / iam:CreateRole /
# iam:AttachRolePolicy on the caller.
set -euo pipefail
export AWS_PAGER=""   # stdout must be exactly the role ARN; keep the CLI from paginating into it

ROLE_NAME="${QWEN_WEBSEARCH_ROLE_NAME:-qwen-agents-websearch}"
BEDROCK_POLICY_ARN="arn:aws:iam::aws:policy/AmazonBedrockFullAccess"
say(){ printf '[websearch-role] %s\n' "$*" >&2; }

trust="$(mktemp)"; trap 'rm -f "$trust"' EXIT
cat > "$trust" <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
  "Principal":{"Service":"pods.eks.amazonaws.com"},
  "Action":["sts:AssumeRole","sts:TagSession"]}]}
JSON

if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  say "role $ROLE_NAME exists — reusing"
else
  say "creating role $ROLE_NAME (Pod Identity trust)"
  aws iam create-role --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://$trust" \
    --description "Qwen EKS agents: Bedrock web_search via Pod Identity" >/dev/null
fi
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$BEDROCK_POLICY_ARN" >/dev/null
say "attached AmazonBedrockFullAccess"

aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text

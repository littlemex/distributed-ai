#!/usr/bin/env bash
# Create (idempotently) a least-privilege IAM role the agents assume via EKS Pod Identity to call
# Amazon Bedrock's server-side web_search. deploy.sh --websearch calls this when QWEN_BEDROCK_ROLE_ARN
# is unset; it also runs standalone. The ONLY thing printed to stdout is the role ARN, so it can be
# captured directly:  QWEN_BEDROCK_ROLE_ARN="$(scripts/setup-websearch-role.sh)".
#
# Trust: pods.eks.amazonaws.com (Pod Identity). Permissions: Bedrock model invocation only — this is
# deliberately narrower than AmazonBedrockFullAccess. Override the name with QWEN_WEBSEARCH_ROLE_NAME.
# Needs iam:GetRole / iam:CreateRole / iam:PutRolePolicy on the caller.
set -euo pipefail
export AWS_PAGER=""   # stdout must be exactly the role ARN; keep the CLI from paginating into it

ROLE_NAME="${QWEN_WEBSEARCH_ROLE_NAME:-qwen-agents-websearch}"
say(){ printf '[websearch-role] %s\n' "$*" >&2; }

trust="$(mktemp)"; policy="$(mktemp)"
trap 'rm -f "$trust" "$policy"' EXIT
cat > "$trust" <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
  "Principal":{"Service":"pods.eks.amazonaws.com"},
  "Action":["sts:AssumeRole","sts:TagSession"]}]}
JSON
cat > "$policy" <<'JSON'
{"Version":"2012-10-17","Statement":[{"Sid":"BedrockInvoke","Effect":"Allow",
  "Action":["bedrock:InvokeModel","bedrock:InvokeModelWithResponseStream","bedrock:Converse","bedrock:ConverseStream"],
  "Resource":"*"}]}
JSON

if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  say "role $ROLE_NAME exists — reusing (refreshing the inline policy)"
else
  say "creating role $ROLE_NAME (Pod Identity trust)"
  aws iam create-role --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://$trust" \
    --description "Qwen EKS agents: Bedrock web_search via Pod Identity (least privilege)" >/dev/null
fi
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name bedrock-websearch \
  --policy-document "file://$policy" >/dev/null
say "inline policy bedrock-websearch applied"

aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text

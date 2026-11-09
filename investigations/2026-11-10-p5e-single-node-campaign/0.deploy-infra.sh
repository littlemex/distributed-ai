#!/bin/bash
# Deploy the VPC, security group, results bucket, FSx control function, launch template and the
# scheduled launch. Nothing that bills by the hour is created except the NAT gateway.
set -euo pipefail
cd "$(dirname "$0")"
. ./env.sh
: "${AMI_ID:?}" "${AVAILABILITY_ZONE:?}"
export AWS_DEFAULT_REGION=$AWS_REGION CDK_DEFAULT_REGION=$AWS_REGION
export CDK_DEFAULT_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
cd cdk
[ -d node_modules ] || npm ci
aws cloudformation describe-stacks --stack-name CDKToolkit --region "$AWS_REGION" > /dev/null 2>&1 || \
  npx cdk bootstrap "aws://$CDK_DEFAULT_ACCOUNT/$AWS_REGION" -c availabilityZone="$AVAILABILITY_ZONE" -c amiId="$AMI_ID"
npx cdk deploy --require-approval never \
  -c stackName="$STACK_NAME" -c availabilityZone="$AVAILABILITY_ZONE" -c amiId="$AMI_ID" \
  -c instanceType="$INSTANCE_TYPE" -c capacityReservationId="${CAPACITY_RESERVATION_ID:-}" \
  -c launchAtUtc="${LAUNCH_AT_UTC:-}" -c cleanupAtUtc="${CLEANUP_AT_UTC:-}" "$@"

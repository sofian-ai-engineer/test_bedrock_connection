#!/usr/bin/env bash
# Creates (idempotently) the IAM OIDC provider for the cluster + an IRSA role the
# test pod's ServiceAccount can assume. Writes the role ARN to .generated/role-arn.
set -uo pipefail
cd "$(dirname "$0")/.."
source ./config.env
[ -n "$AWS_PROFILE_NAME" ] && export AWS_PROFILE="$AWS_PROFILE_NAME"
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
mkdir -p .generated

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text) || die "no AWS credentials"
ISSUER=$(aws eks describe-cluster --name "$CLUSTER_NAME" --query 'cluster.identity.oidc.issuer' --output text) \
  || die "cannot describe cluster $CLUSTER_NAME"
OIDC_PATH=${ISSUER#https://}
PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PATH}"
echo "account=$ACCOUNT_ID"
echo "oidc=$OIDC_PATH"

say "IAM OIDC provider"
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$PROVIDER_ARN" >/dev/null 2>&1; then
  echo "already associated"
else
  echo "creating..."
  if ! aws iam create-open-id-connect-provider --url "$ISSUER" --client-id-list sts.amazonaws.com >/dev/null 2>&1; then
    THUMB=$(echo | openssl s_client -servername "${OIDC_PATH%%/*}" -connect "${OIDC_PATH%%/*}:443" -showcerts 2>/dev/null \
            | openssl x509 -fingerprint -sha1 -noout 2>/dev/null | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f')
    [ -n "$THUMB" ] || die "could not create OIDC provider. Fallback: eksctl utils associate-iam-oidc-provider --cluster $CLUSTER_NAME --region $REGION --approve"
    aws iam create-open-id-connect-provider --url "$ISSUER" --client-id-list sts.amazonaws.com \
      --thumbprint-list "$THUMB" >/dev/null || die "create-open-id-connect-provider failed"
  fi
  echo "created"
fi

say "IAM role $ROLE_NAME"
TRUST=$(mktemp)
cat > "$TRUST" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "${PROVIDER_ARN}" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": { "StringEquals": {
      "${OIDC_PATH}:sub": "system:serviceaccount:${NAMESPACE}:${SA_NAME}",
      "${OIDC_PATH}:aud": "sts.amazonaws.com"
    }}
  }]
}
JSON

if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "file://$TRUST" || die "update trust failed"
  echo "role exists — trust policy refreshed"
else
  aws iam create-role --role-name "$ROLE_NAME" \
    --description "EKS pod test for Bedrock VPC endpoint connectivity" \
    --assume-role-policy-document "file://$TRUST" >/dev/null || die "create-role failed"
  echo "role created"
fi
rm -f "$TRUST"

aws iam put-role-policy --role-name "$ROLE_NAME" \
  --policy-name bedrock-endpoint-test \
  --policy-document file://iam/bedrock-policy.json || die "put-role-policy failed"
echo "inline policy attached"

ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)
echo "$ROLE_ARN" > .generated/role-arn
say "ROLE_ARN = $ROLE_ARN   (saved to .generated/role-arn)"
echo "next: ./run-test.sh"

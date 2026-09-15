#!/usr/bin/env bash
# Creates (idempotently) the IAM OIDC provider for an EKS cluster and the IRSA role
# that bedrock-test.yaml's ServiceAccount assumes. Prints the role ARN to paste in.
#
#   ./iam/setup-irsa.sh <cluster-name> [--patch-yaml]
#
#   --patch-yaml   also write the ARN into bedrock-test.yaml for you
#
# Overridable with env vars: REGION, NAMESPACE, SA_NAME, ROLE_NAME, AWS_PROFILE
set -uo pipefail
cd "$(dirname "$0")/.."

REGION="${REGION:-ap-southeast-1}"
NAMESPACE="${NAMESPACE:-bedrock-test}"
SA_NAME="${SA_NAME:-bedrock-test-sa}"
ROLE_NAME="${ROLE_NAME:-eks-bedrock-endpoint-test}"
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

CLUSTER_NAME=""; PATCH=0
for a in "$@"; do
  case "$a" in
    --patch-yaml) PATCH=1 ;;
    -*) die "unknown flag: $a" ;;
    *)  CLUSTER_NAME="$a" ;;
  esac
done

command -v aws >/dev/null 2>&1 || die "aws cli not installed (brew install awscli)"
aws sts get-caller-identity >/dev/null 2>&1 || die "no valid AWS credentials.
  SSO:  aws configure sso   then   aws sso login --profile <name>   then   export AWS_PROFILE=<name>
  Keys: aws configure"

if [ -z "$CLUSTER_NAME" ]; then
  say "no cluster given — EKS clusters in $REGION:"
  aws eks list-clusters --query 'clusters' --output table
  die "usage: ./iam/setup-irsa.sh <cluster-name>"
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ISSUER=$(aws eks describe-cluster --name "$CLUSTER_NAME" --query 'cluster.identity.oidc.issuer' --output text) \
  || die "cannot describe cluster $CLUSTER_NAME in $REGION"
OIDC_PATH=${ISSUER#https://}
PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PATH}"
echo "account=$ACCOUNT_ID  cluster=$CLUSTER_NAME  region=$REGION"

say "IAM OIDC provider"
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$PROVIDER_ARN" >/dev/null 2>&1; then
  echo "already associated"
else
  echo "creating..."
  if ! aws iam create-open-id-connect-provider --url "$ISSUER" --client-id-list sts.amazonaws.com >/dev/null 2>&1; then
    THUMB=$(echo | openssl s_client -servername "${OIDC_PATH%%/*}" -connect "${OIDC_PATH%%/*}:443" -showcerts 2>/dev/null \
            | openssl x509 -fingerprint -sha1 -noout 2>/dev/null | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f')
    [ -n "$THUMB" ] || die "could not create OIDC provider. Fallback:
  eksctl utils associate-iam-oidc-provider --cluster $CLUSTER_NAME --region $REGION --approve"
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
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "file://$TRUST" \
    || die "update trust policy failed"
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
say "ROLE_ARN = $ROLE_ARN"

if [ "$PATCH" -eq 1 ] && [ -f bedrock-test.yaml ]; then
  sed -i.bak -E "s|(eks\.amazonaws\.com/role-arn: ).*|\1${ROLE_ARN}|" bedrock-test.yaml && rm -f bedrock-test.yaml.bak
  echo "bedrock-test.yaml updated — next: kubectl apply -f bedrock-test.yaml"
else
  echo
  echo "Paste it into bedrock-test.yaml:"
  echo "    eks.amazonaws.com/role-arn: $ROLE_ARN"
  echo "(or re-run with --patch-yaml to have it written for you)"
fi

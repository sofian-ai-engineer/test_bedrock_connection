#!/usr/bin/env bash
# Prepares this machine: aws cli, kubeconfig for the EKS cluster, and a read-only
# inventory of what Bedrock VPC endpoints actually exist in the cluster's VPC.
set -uo pipefail
cd "$(dirname "$0")"
source ./config.env

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$CLUSTER_NAME" = "CHANGE-ME" ] && die "set CLUSTER_NAME in config.env first"
[ -n "$AWS_PROFILE_NAME" ] && export AWS_PROFILE="$AWS_PROFILE_NAME"
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"

say "1/5 aws cli"
if ! command -v aws >/dev/null 2>&1; then
  command -v brew >/dev/null 2>&1 || die "aws cli missing and no brew. Install: https://aws.amazon.com/cli/"
  echo "aws cli not found — installing with: brew install awscli"
  brew install awscli || die "brew install awscli failed"
fi
aws --version

say "2/5 credentials"
aws sts get-caller-identity --output table || die "no valid AWS credentials.
  SSO:  aws configure sso   then   aws sso login --profile <name>
  Keys: aws configure
  Then set AWS_PROFILE_NAME in config.env."

say "3/5 kubeconfig for EKS cluster '$CLUSTER_NAME'"
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME" \
  ${AWS_PROFILE_NAME:+--profile "$AWS_PROFILE_NAME"} || die "update-kubeconfig failed.
  List clusters with: aws eks list-clusters --region $REGION"
kubectl get nodes || die "kubectl cannot reach the cluster (check aws-auth / access entries)"

say "4/5 Bedrock VPC endpoints in the cluster's VPC (read-only preflight)"
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
          --query 'cluster.resourcesVpcConfig.vpcId' --output text)
echo "cluster VPC: $VPC_ID"
aws ec2 describe-vpc-endpoints --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'VpcEndpoints[].{Service:ServiceName,Type:VpcEndpointType,PrivateDNS:PrivateDnsEnabled,State:State}' \
  --output table
for SVC in bedrock bedrock-runtime sts; do
  FOUND=$(aws ec2 describe-vpc-endpoints --region "$REGION" \
            --filters "Name=vpc-id,Values=$VPC_ID" "Name=service-name,Values=com.amazonaws.$REGION.$SVC" \
            --query 'VpcEndpoints[0].VpcEndpointId' --output text 2>/dev/null)
  if [ "$FOUND" = "None" ] || [ -z "$FOUND" ]; then
    echo "  MISSING: com.amazonaws.$REGION.$SVC  <-- the pod test will fail on this one"
  else
    echo "  present: com.amazonaws.$REGION.$SVC ($FOUND)"
  fi
done

say "5/5 next steps"
echo "  ./iam/setup-irsa.sh     # create the IAM role + OIDC trust for the test pod"
echo "  ./run-test.sh           # run the pod and print the verdict"

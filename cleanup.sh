#!/usr/bin/env bash
# Prints the commands to remove what this project created. It does NOT run them —
# nothing in this repo deletes anything in your cluster. Copy what you want.
set -uo pipefail
cd "$(dirname "$0")"
source ./config.env

echo
echo "Test pods created so far in namespace '$NAMESPACE':"
kubectl get pods -n "$NAMESPACE" -l app=bedrock-endpoint-test \
  -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,AGE:.metadata.creationTimestamp 2>/dev/null \
  || echo "  (namespace not found or not reachable)"

cat <<TXT

To remove them yourself, run whichever of these you want:

  # just the finished test pods (keeps the namespace, SA and configmap for re-runs)
  kubectl delete pods -n $NAMESPACE -l app=bedrock-endpoint-test

  # everything this project created in the cluster
  kubectl delete namespace $NAMESPACE

  # the IAM role (outside the cluster; the cluster's OIDC provider is shared — leave it)
  aws iam delete-role-policy --role-name $ROLE_NAME --policy-name bedrock-endpoint-test
  aws iam delete-role --role-name $ROLE_NAME

Local files only (safe, touches nothing remote):
  rm -rf .generated
TXT

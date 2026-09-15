#!/usr/bin/env bash
# Renders the manifest, runs the test pod, streams the verdict, exits non-zero if
# the VPC endpoint path to Bedrock is broken.
#   ./run-test.sh                 full test (network + IRSA + real Bedrock call)
#   ./run-test.sh --network-only  skip IRSA; only DNS/TCP checks (no IAM role needed)
#
# This script NEVER deletes anything in the cluster. Every run creates a new,
# uniquely named pod and leaves it in place; nothing existing is removed or
# replaced. See ./cleanup.sh for the (manual) removal commands.
set -uo pipefail
cd "$(dirname "$0")"
source ./config.env

NETWORK_ONLY=0
for a in "$@"; do
  case "$a" in
    --network-only) NETWORK_ONLY=1 ;;
    --keep)         ;;  # accepted for compatibility: pods are always kept now
    *) echo "unknown flag: $a"; exit 2 ;;
  esac
done

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
mkdir -p .generated

ROLE_ARN="${ROLE_ARN:-}"
if [ "$NETWORK_ONLY" -eq 0 ]; then
  [ -z "$ROLE_ARN" ] && [ -f .generated/role-arn ] && ROLE_ARN=$(cat .generated/role-arn)
  [ -z "$ROLE_ARN" ] && die "no IRSA role. Run ./iam/setup-irsa.sh, or use --network-only"
fi

CTX=$(kubectl config current-context)
say "context: $CTX   cluster: $CLUSTER_NAME   region: $REGION"
case "$CTX" in
  *"$CLUSTER_NAME"*|arn:aws:eks:*) ;;
  *) echo "  warning: current kube context does not look like the EKS cluster — run ./setup.sh" ;;
esac

# A fresh name per run, so a re-run never has to delete or overwrite a previous pod.
RUN_POD="${POD_NAME}-$(date +%Y%m%d-%H%M%S)"
RENDERED=.generated/bedrock-test.rendered.yaml
sed -e "s|__NAMESPACE__|$NAMESPACE|g" \
    -e "s|__SA_NAME__|$SA_NAME|g" \
    -e "s|__POD_NAME__|$RUN_POD|g" \
    -e "s|__REGION__|$REGION|g" \
    -e "s|__MODEL_ID__|$MODEL_ID|g" \
    -e "s|__TEST_IMAGE__|$TEST_IMAGE|g" \
    -e "s|__ROLE_ARN__|${ROLE_ARN:-none}|g" \
    k8s/bedrock-test.yaml > "$RENDERED"

if [ "$NETWORK_ONLY" -eq 1 ]; then
  # drop the IRSA annotation entirely so the SA is a plain, credential-less SA
  sed -i.bak -e '/eks.amazonaws.com\/role-arn/d' -e '/^  annotations:$/d' "$RENDERED" && rm -f "$RENDERED.bak"
  echo "  network-only mode: no IRSA annotation (steps 3-5 will report no credentials)"
fi

say "applying (additive only — nothing is deleted)"
echo "  pod: $RUN_POD  namespace: $NAMESPACE"
kubectl apply -f "$RENDERED" || die "kubectl apply failed"

say "waiting for pod to finish (timeout 4m)"
DEADLINE=$(( $(date +%s) + 240 ))
PHASE=""
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  PHASE=$(kubectl get pod "$RUN_POD" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)
  case "$PHASE" in Succeeded|Failed) break ;; esac
  REASON=$(kubectl get pod "$RUN_POD" -n "$NAMESPACE" \
            -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)
  case "$REASON" in
    ErrImagePull|ImagePullBackOff)
      kubectl describe pod "$RUN_POD" -n "$NAMESPACE" | tail -20
      die "cannot pull $TEST_IMAGE. The nodes need egress to ECR Public — either a NAT/IGW route,
  or interface endpoints com.amazonaws.$REGION.ecr.api + .ecr.dkr and an S3 gateway endpoint.
  Workaround: set TEST_IMAGE in config.env to an image already present in your registry
  (any Amazon Linux / Debian image with bash + aws cli works)." ;;
  esac
  printf '.'; sleep 3
done
echo

say "pod output"
kubectl logs "$RUN_POD" -n "$NAMESPACE" || kubectl describe pod "$RUN_POD" -n "$NAMESPACE"

EXIT=$(kubectl get pod "$RUN_POD" -n "$NAMESPACE" \
        -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null)

echo
echo "  pod kept: kubectl logs $RUN_POD -n $NAMESPACE"
echo "  remove it yourself when done: kubectl delete pod $RUN_POD -n $NAMESPACE"

case "${EXIT:-timeout}" in
  0) say "RESULT: Bedrock VPC endpoint path from EKS is working"; exit 0 ;;
  timeout) die "pod did not finish in time (phase=$PHASE)" ;;
  *) printf '\n\033[31m==> RESULT: the Bedrock VPC endpoint is NOT correct (see FAIL lines above)\033[0m\n'; exit 1 ;;
esac

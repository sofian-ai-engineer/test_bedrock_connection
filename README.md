# Bedrock VPC endpoint test from EKS

Runs one throwaway pod in your EKS cluster that answers a single question:
**is the VPC interface endpoint to Amazon Bedrock set up correctly?**

The pod walks five checks and, importantly, separates *network* problems from
*permission* problems — an `AccessDenied` from Bedrock still proves the VPC
endpoint works, so the script reports that as a pass on connectivity.

| # | Check | What a failure means |
|---|-------|----------------------|
| 1 | `bedrock-runtime.<region>.amazonaws.com` resolves to a **private** IP | No interface endpoint in this VPC, "Enable DNS name" off, or VPC DNS support disabled |
| 2 | TCP 443 open on that IP | Endpoint security group doesn't allow 443 from the pod/node CIDR |
| 3 | `sts get-caller-identity` | IRSA broken, or no `com.amazonaws.<region>.sts` endpoint (IRSA needs STS) |
| 4 | `bedrock list-foundation-models` | Control-plane endpoint (`com.amazonaws.<region>.bedrock`) |
| 5 | Real `converse` / `invoke-model` call | Runtime endpoint (`com.amazonaws.<region>.bedrock-runtime`) + IAM + endpoint policy |

## Quick start

```bash
vi config.env          # set CLUSTER_NAME (and REGION if not ap-southeast-1)
./setup.sh             # aws cli, kubeconfig, and a preflight of existing VPC endpoints
./iam/setup-irsa.sh    # OIDC provider + IAM role the test pod assumes
./run-test.sh          # run the pod, print the verdict, clean up after itself
```

Exit code is 0 when the endpoint path works, 1 when it doesn't.

Exit code is 0 when the endpoint path works, 1 when it doesn't.

## Nothing here deletes anything in your cluster

Every operation is additive — `kubectl apply` of a Namespace, ServiceAccount,
ConfigMap and Pod, and nothing else. Specifically:

- each run creates a **new, timestamped pod** (`bedrock-endpoint-test-20260915-143001`),
  so a re-run never has to delete or overwrite the previous one;
- finished pods are **left in place** for you to inspect;
- `cleanup.sh` only **prints** the removal commands — you run them if you want to.

```bash
./run-test.sh --network-only   # DNS/TCP only — no IAM role needed at all
./cleanup.sh                   # lists the test pods + prints removal commands (runs none)
```

## Sample output

```
=== 1. DNS — do the endpoints resolve to PRIVATE addresses? ===
  [PASS] bedrock-runtime.ap-southeast-1.amazonaws.com -> 10.0.2.117 (private — resolving to the VPC endpoint ENI)
=== 5. Bedrock runtime — com.amazonaws.ap-southeast-1.bedrock-runtime (the real test) ===
  [PASS] Converse succeeded — model replied: pong

=== VERDICT ===
  pass=8  warn=0  fail=0
  ✅ VPC endpoint to Bedrock is CORRECT — private DNS, connectivity, IAM and inference all work.
```

## Things worth knowing before you run it

- **Three endpoints, not one.** Bedrock needs `bedrock-runtime` for inference and
  `bedrock` for the control plane, and IRSA additionally needs `sts`. `setup.sh`
  prints which of the three exist in your cluster's VPC before you run anything.
- **Image pull.** The pod uses `public.ecr.aws/aws-cli/aws-cli`. In a fully private
  cluster that pull needs ECR endpoints (`ecr.api`, `ecr.dkr`, plus an S3 gateway
  endpoint) or a NAT route. If it can't pull, `run-test.sh` says so and tells you to
  point `TEST_IMAGE` at an image your nodes already have.
- **Model id.** `MODEL_ID` defaults to `apac.anthropic.claude-sonnet-5`, the APAC
  cross-region inference profile. List what your account actually has with
  `aws bedrock list-inference-profiles --region ap-southeast-1`. A wrong model id
  produces a `ValidationException` — which the script reports as *endpoint reached,
  network fine*, so it never masks the connectivity answer.
- **EKS Pod Identity** is a supported alternative to IRSA. If you use it, skip
  `iam/setup-irsa.sh`, create a pod identity association for `bedrock-test/bedrock-test-sa`,
  and run `./run-test.sh --network-only` — or edit the SA annotation out of the manifest.

## Files

```
config.env                 all knobs (region, cluster, namespace, model, image)
setup.sh                   aws cli + kubeconfig + VPC endpoint preflight
iam/setup-irsa.sh          IAM OIDC provider + role + trust policy (idempotent)
iam/bedrock-policy.json    permissions granted to the test pod
k8s/bedrock-test.yaml      Namespace, ServiceAccount, ConfigMap (the test script), Pod
run-test.sh                render + apply + wait + logs + verdict (never deletes)
cleanup.sh                 prints the removal commands — does not run them
```

# Bedrock VPC endpoint test from EKS

One YAML file. Apply it, read the logs, and you know whether your VPC interface
endpoint to Amazon Bedrock is set up correctly.

The pod runs five checks and separates *network* problems from *permission*
problems — an `AccessDenied` from Bedrock still proves the endpoint works, so
that is reported as a pass on connectivity, not a failure.

| # | Check | What a failure means |
|---|-------|----------------------|
| 1 | `bedrock-runtime.<region>.amazonaws.com` resolves to a **private** IP | No interface endpoint in this VPC, "Enable DNS name" off, or VPC DNS support disabled |
| 2 | TCP 443 open on that IP | Endpoint security group doesn't allow 443 from the pod/node CIDR |
| 3 | `sts get-caller-identity` | IRSA broken, or no `com.amazonaws.<region>.sts` endpoint (IRSA needs STS) |
| 4 | `bedrock list-foundation-models` | Control-plane endpoint (`com.amazonaws.<region>.bedrock`) |
| 5 | Real `converse` / `invoke-model` call | Runtime endpoint (`com.amazonaws.<region>.bedrock-runtime`) + IAM + endpoint policy |

## Usage

**1. Create the IAM role** the pod assumes (once per cluster):

```bash
aws sso login --profile <your-profile>     # or: aws configure
export AWS_PROFILE=<your-profile>
./iam/setup-irsa.sh <your-cluster-name> --patch-yaml
```

`--patch-yaml` writes the resulting role ARN straight into `bedrock-test.yaml`.
Without it, the script just prints the ARN for you to paste in.

**2. Edit the remaining values** in `bedrock-test.yaml` — they're marked `EDIT`:
your region (if not `ap-southeast-1`) and the model id.

**3. Run it:**

```bash
kubectl apply -f bedrock-test.yaml
kubectl logs -f bedrock-endpoint-test -n bedrock-test
```

To run again:

```bash
kubectl delete pod bedrock-endpoint-test -n bedrock-test
kubectl apply -f bedrock-test.yaml
```

### No IAM role? Skip step 1

Delete the `eks.amazonaws.com/role-arn` annotation from `bedrock-test.yaml` and
apply it as-is. Checks 1 and 2 (DNS and TCP — the actual VPC endpoint questions)
still run and still give you a real answer; 3–5 will report missing credentials.

## Reading the result

```
=== VERDICT ===
  pass=9  warn=0  fail=0
  ✅ VPC endpoint to Bedrock is CORRECT — DNS, connectivity, IAM and inference all work.
```

| Result | What it means |
|--------|---------------|
| `✅ CORRECT` | Private DNS, routing, IAM and inference all work. Done. |
| `[WARN] ENDPOINT REACHED, call rejected` | **Your networking is fine.** The VPC endpoint is correct; the failure is IAM, model access in the Bedrock console, or the endpoint policy. Don't touch the VPC config. |
| `[FAIL] ... (PUBLIC — traffic leaves via IGW/NAT)` | The hostname resolves to a public IP, bypassing your endpoint. Usually "Enable DNS name" is off on the endpoint, or the VPC has `enableDnsHostnames` disabled. |
| `[FAIL] ...:443 refused/timed out` | Endpoint exists and DNS is right, but its security group doesn't allow 443 from your node/pod CIDR. The most common cause. |

The pod exits 0 when the endpoint path works, 1 when it doesn't — so it also
works as a CI gate.

## Optional preflight from the AWS side

To see which endpoints exist before you run anything:

```bash
VPC=$(aws eks describe-cluster --name <cluster> --query 'cluster.resourcesVpcConfig.vpcId' --output text)
aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC" \
  --query 'VpcEndpoints[].{Service:ServiceName,PrivateDNS:PrivateDnsEnabled,State:State}' --output table
```

You want `com.amazonaws.<region>.bedrock-runtime`, `.bedrock`, and — for IRSA —
`.sts`, all with `PrivateDNS: True`.

## Things worth knowing

- **Three endpoints, not one.** `bedrock-runtime` for inference, `bedrock` for the
  control plane, and `sts` for IRSA. A missing `sts` endpoint is the usual reason a
  pod that "should" work gets no credentials at all.
- **Image pull.** The pod uses `public.ecr.aws/aws-cli/aws-cli`. In a fully private
  cluster that needs ECR endpoints (`ecr.api`, `ecr.dkr`, plus an S3 gateway endpoint)
  or a NAT route. If it can't pull, swap `image:` for one your nodes already have —
  anything with bash and the AWS CLI works.
- **Model id.** Defaults to `apac.anthropic.claude-sonnet-5`, the APAC cross-region
  inference profile. List yours with `aws bedrock list-inference-profiles --region <region>`.
  A wrong id gives a `ValidationException`, which is reported as *endpoint reached,
  network fine* — it never masks the connectivity answer.
- **EKS Pod Identity** works too: delete the annotation and create a pod identity
  association for `bedrock-test/bedrock-test-sa` instead.
- The manifest only ever **adds** things — a Namespace, ServiceAccount, ConfigMap and
  Pod. Nothing existing is removed or modified.

## Files

```
bedrock-test.yaml          the whole test — Namespace, SA, ConfigMap (script), Pod
iam/setup-irsa.sh          creates the IAM OIDC provider + role (idempotent)
iam/bedrock-policy.json    permissions granted to the test pod
```

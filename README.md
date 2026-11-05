# Cell-based LLM inference on Amazon EKS: stub milestone

An OpenAI-compatible HTTPS API on one hostname, served by a cell-based platform on Amazon EKS. This repository implements **Phase 1: the stub milestone**. Each cell runs NVIDIA Dynamo (frontend + KV Router) with the Dynamo **mocker** as a fake engine on CPU instances. The design and the Definition of Done (DoD) are in [`docs/architecture.md`](docs/architecture.md).

```
client ──HTTPS──► Route 53 (latency record) ──► public ALB (ACM TLS, Cognito JWT check)
                                                   │ TargetGroupBinding (IP targets)
                                                   ▼
                                    regional router cluster (EKS): router pods
                                    cell = sha256(session-id) mod N_cells
                                                   │ internal NLB per cell
                                   ┌───────────────┴───────────────┐
                                   ▼                               ▼
                       cell a (EKS, AZ 1)                cell b (EKS, AZ 2)
                       Dynamo frontend + KV Router       Dynamo frontend + KV Router
                       mocker workers on Karpenter       mocker workers on Karpenter
                       c8i.48xlarge + EFA                c8i.48xlarge + EFA
```

## Repository layout

| Path | Contents |
|---|---|
| `docs/architecture.md` | Architecture snapshot (the source of truth) |
| `infra/modules/network` | VPC, /18 private and /24 public subnets per AZ, NAT gateway per AZ, VPC endpoints |
| `infra/modules/edge` | ACM certificate, Cognito (client credentials), public ALB with JWT validation, Route 53 latency record |
| `infra/modules/eks-base` | Shared EKS settings for every cluster (wrapper around `terraform-aws-modules/eks`): private endpoint, access entries, pinned add-ons including the Pod Identity Agent, system node group |
| `infra/modules/regional` | Regional router cluster (on `eks-base`), ECR repositories (`router`, `dynamo-planner`), Load Balancer Controller IAM (Pod Identity) |
| `infra/modules/cell` | One cell: cluster in one AZ (on `eks-base`), Karpenter IAM/SQS (Pod Identity), placement group, EFA security group, and the rendered inference EC2NodeClass + NodePool |
| `infra/envs/region` | One Region environment that lists the cells (`terraform.tfvars.example`) |
| `platform/` | Helm values and templates: Load Balancer Controller, Karpenter (EC2NodeClass + inference NodePool templates, rendered by Terraform), EFA device plugin, Dynamo, SOCI node config for inference nodes |
| `router/` | Regional router (FastAPI + uvicorn + httpx), tests, Dockerfile, Kubernetes manifests |
| `workloads/stub-engine` | `DynamoGraphDeployment` (frontend + mocker) and the internal NLB Service |
| `workloads/vllm` | Placeholder for Phase 2 |
| `scripts/` | Manual, numbered deploy steps, verification and teardown |

## Prerequisites

### AWS account

- A **public Route 53 hosted zone** for the domain that holds the API hostname (for example zone `example.com`, hostname `api.example.com`).
- **On-demand vCPU quota** for "Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances" of at least about **450 vCPUs** in the Region. Each inference node is a `c8i.48xlarge` with 192 vCPUs, one per cell. The system nodes add about 40 vCPUs.
- `c8i.48xlarge` offered in both cell AZs. Terraform checks this and fails the plan if it is not.
- Permissions to create VPC, EKS, EC2, ELB, IAM, Cognito, ACM, Route 53, ECR, SQS, EventBridge and SSM resources.

> **Cost:** each `c8i.48xlarge` costs about $8–9 per hour on demand, so two cells cost about $17 per hour while inference nodes run. On top of that you pay for three EKS control planes, NAT gateways, the load balancers and the system nodes. Run `scripts/90-teardown.sh` when you are done.

### Operator host

The operator host is the machine where you run Terraform and the scripts. It must be Linux on x86_64, because the SOCI conversion of the `dynamo-planner` image needs containerd. It needs these tools:

| Tool | Version used |
|---|---|
| Terraform | 1.17.x |
| AWS CLI v2 + Session Manager plugin | current |
| kubectl | 1.36 or later (clusters run Kubernetes 1.37) |
| Helm | 3.x (3.19 tested) |
| Docker (with buildx) | current, to build the router image |
| containerd 2.x + nerdctl | to pull, convert and push the `dynamo-planner` mirror (run with `sudo`) |
| `soci` CLI | 0.16.1 (from the [soci-snapshotter release](https://github.com/awslabs/soci-snapshotter/releases/tag/v0.16.1)) |
| jq, curl, git, envsubst (gettext), setsid (util-linux) | any |
| Python 3.11+ with `openai==3.46.0` | for DoD 7 |

`scripts/00-check-prereqs.sh` checks all of them.

### Operator instance (SSM tunnel)

All EKS API endpoints are private. kubectl and Helm reach them through an SSM port-forwarding tunnel via an **operator instance** inside the VPC. You create this instance manually after step 1, and it is not part of this repository. It needs:

- Ubuntu Server 26.04 LTS in one of the VPC's **private** subnets. The SSM agent ships with the Ubuntu AMIs.
- An instance profile with `AmazonSSMManagedInstanceCore`. The VPC already has endpoints for SSM, ssmmessages and ec2messages.
- A security group that allows outbound TCP 443 to the VPC CIDR. Every cluster security group accepts 443 from the VPC CIDR.

The tunnel carries only the TLS connection. kubectl still authenticates with the operator host's own AWS credentials. That identity must be the one that ran `terraform apply` or be listed in `operator_principal_arns`.

## Configure

```bash
cd infra/envs/region
cp terraform.tfvars.example terraform.tfvars   # git-ignored
```

Set `region`, `hosted_zone_name`, `api_hostname`, the two `cells` (each in a different AZ), and `operator_principal_arns`. The repository contains no environment values. Defaults that you normally keep:

| Variable | Default |
|---|---|
| `vpc_cidr` | `10.0.0.0/16` |
| `cells.*.inference_instance_type` | `c8i.48xlarge` |
| `cells.*.efa_enabled` | `true` |
| `kubernetes_version` | `1.37` |

## Deploy order

Run the steps from the repository root. Each step can be re-run.

| Step | Command | What it does |
|---|---|---|
| 0 | `scripts/00-check-prereqs.sh` | Checks tools and AWS credentials |
| 1 | `scripts/10-terraform-apply.sh` | `terraform apply` creates the VPC, ACM, Cognito, ALB, Route 53 record, ECR, the router cluster and both cells (about 30 min) |
| – | *create the operator instance* | See [Operator instance](#operator-instance-ssm-tunnel) |
| 2 | `OPERATOR_INSTANCE_ID=i-… scripts/20-tunnels.sh start` | Opens SSM tunnels and writes `.state/region/kubeconfig` with one context per cluster |
| 3 | `scripts/30-images.sh` | Builds and pushes the router image with Docker (git-SHA tag). Mirrors `dynamo-planner:1.6.1` from NGC, converts it to a SOCI-enabled image (index manifest v2) and pushes it to ECR |
| 4 | `scripts/40-platform-router.sh` | AWS Load Balancer Controller on the router cluster |
| 5 | `scripts/41-platform-cells.sh` | Per cell: Load Balancer Controller, Karpenter, `kubectl apply` of the EC2NodeClass and NodePool that Terraform rendered, EFA device plugin, Dynamo platform (operator only) |
| 6 | `scripts/50-stub-engine.sh` | Per cell: the `DynamoGraphDeployment` (frontend + KV Router + mocker) and the internal NLB. Karpenter launches the inference node (about 10 min) |
| 7 | `scripts/60-router.sh` | Router ConfigMaps (cell list = internal NLB URLs), Deployment and TargetGroupBinding. Waits for healthy ALB targets |
| 8 | `scripts/70-verify.sh` | Runs every DoD check below |
| – | `scripts/20-tunnels.sh stop` | Closes the tunnels |
| – | `scripts/90-teardown.sh` | Deletes the controller-created NLBs and Karpenter nodes, then runs `terraform destroy` |

To use kubectl yourself, run `export KUBECONFIG=$PWD/.state/region/kubeconfig`. The contexts are named after the clusters: `llm-<region>-router`, `llm-<region>-a` and `llm-<region>-b`.

## Verify the Definition of Done

`scripts/70-verify.sh` runs all nine checks and exits non-zero if any fails. To run them by hand, set up the shell first:

```bash
export KUBECONFIG=$PWD/.state/region/kubeconfig
TF="terraform -chdir=infra/envs/region"
HOST=$($TF output -json deploy | jq -r .api_hostname)
API=https://$HOST/v1

TOKEN=$(curl -s \
  -u "$($TF output -json deploy | jq -r .cognito.client_id):$($TF output -raw cognito_client_secret)" \
  -d grant_type=client_credentials \
  -d scope=$($TF output -json deploy | jq -r .cognito.required_scope) \
  "$($TF output -json deploy | jq -r .cognito.token_endpoint)" | jq -r .access_token)

MODEL=$(curl -s $API/models -H "Authorization: Bearer $TOKEN" | jq -r '.data[0].id')   # Qwen/Qwen3-0.6B
```

### 1. Terraform created the Region

```bash
$TF state list | grep -E 'aws_vpc.this|aws_acm_certificate.api|aws_cognito_user_pool(_client)?\.|aws_lb.this|aws_route53_record.api|aws_ecr_repository|aws_eks_cluster'
$TF output -json deploy | jq '.cells | map_values({cluster_name, availability_zone})'
```

You should see the VPC, certificate, user pool and app client, ALB, Route 53 record, both ECR repositories, and three EKS clusters (router, `a`, `b`). The two cells must be in different AZs.

### 2. Mocker on Karpenter inference nodes with EFA, behind the Dynamo frontend

```bash
for c in a b; do
  CTX=$($TF output -json deploy | jq -r ".cells.$c.cluster_name")
  kubectl --context $CTX get nodes -l karpenter.sh/nodepool=inference \
    -o custom-columns='NODE:.metadata.name,TYPE:.metadata.labels.node\.kubernetes\.io/instance-type,ZONE:.metadata.labels.topology\.kubernetes\.io/zone,EFA:.status.allocatable.vpc\.amazonaws\.com/efa'
  kubectl --context $CTX -n llm-inference get pods -o wide \
    -l nvidia.com/dynamo-graph-deployment-name=stub-engine
done
```

Each cell shows a `c8i.48xlarge` node in its own AZ with `EFA` = `1`. The `worker` (mocker) pods run on that node, and the `frontend` pods run on system nodes.

### 3. SOCI lazy-loads the mocker image

```bash
NODE=$(kubectl --context $CTX get nodes -l karpenter.sh/nodepool=inference -o jsonpath='{.items[0].spec.providerID}')
INSTANCE=${NODE##*/}
CMD=$(aws ssm send-command --instance-ids $INSTANCE --document-name AWS-RunShellScript \
  --parameters 'commands=["findmnt --source soci"]' --query Command.CommandId --output text)
sleep 5; aws ssm get-command-invocation --command-id $CMD --instance-id $INSTANCE --query StandardOutputContent --output text
```

The output lists `fuse.rawBridge` mounts under `/var/lib/soci-snapshotter-grpc/`, one for each lazily loaded layer of `…/dynamo-planner:1.6.1-soci`.

SOCI runs only on inference nodes. They use the snapshotter that ships in the AL2023 AMI, enabled by the nodeadm `FastImagePull` feature gate (`platform/soci/nodeconfig.yaml`). That gate configures SOCI for parallel pull, which never lazy-loads, so `platform/soci/lazy-loading.sh` turns parallel pull off at boot. If the mounts are missing, look for `soci lazy-loading:` in `/var/log/cloud-init-output.log` on the node.

### 4. Streaming returns OpenAI SSE chunks ending with `data: [DONE]`

```bash
curl -N $API/chat/completions \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -H "session-id: demo-1" \
  -d "{\"model\":\"$MODEL\",\"stream\":true,\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}]}"
```

You should see `data: {"object":"chat.completion.chunk",…}` lines, with `data: [DONE]` last.

### 5. The same `session-id` always hits the same cell

```bash
for i in $(seq 10); do
  curl -s -o /dev/null -D - $API/chat/completions \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -H "session-id: sticky-42" \
    -d "{\"model\":\"$MODEL\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" \
    | grep -i '^x-served-cell'
done | sort | uniq -c
```

The result is a single line, for example `10 x-served-cell: b`.

### 6. Different `session-id` values spread across both cells

```bash
for i in $(seq 20); do
  curl -s -o /dev/null -D - $API/chat/completions \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -H "session-id: conv-$i" \
    -d "{\"model\":\"$MODEL\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" \
    | grep -i '^x-served-cell'
done | sort | uniq -c
```

All requests use the same token (the same client), and both `x-served-cell: a` and `x-served-cell: b` appear.

### 7. The official OpenAI Python SDK

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://<api_hostname>/v1",
    api_key="<access token>",                  # $TOKEN
    default_headers={"session-id": "sdk-demo-1"},
)
model = client.models.list().data[0].id
print(client.chat.completions.create(model=model, messages=[{"role": "user", "content": "Hi"}]).choices[0].message.content)
for chunk in client.chat.completions.create(model=model, messages=[{"role": "user", "content": "Hi"}], stream=True):
    print(chunk.choices[0].delta.content or "", end="")
```

The ready-made version is `API_URL=$API ACCESS_TOKEN=$TOKEN python3 scripts/verify_openai_sdk.py` (requires `pip install openai==3.46.0`).

### 8. `POST` without `session-id` returns `400`

```bash
curl -i $API/chat/completions -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}"
```

The response is `HTTP/2 400` with this body:

```json
{"error": {"message": "The 'session-id' header is required and must not be empty.",
           "type": "invalid_request_error", "param": null, "code": "missing_session_id"}}
```

### 9. No valid token returns `401`, and port 80 is closed

```bash
curl -s -o /dev/null -w '%{http_code}\n' $API/models                                          # 401
curl -s -o /dev/null -w '%{http_code}\n' $API/models -H "Authorization: Bearer invalid"       # 401
curl -v --connect-timeout 5 http://$HOST/ ; echo "exit $?"                                    # times out, no listener
```

The ALB rejects these requests before they reach the cluster. The router checks the token again as defense in depth.

## Router

| Behavior | Detail |
|---|---|
| Endpoints | `POST /v1/chat/completions`, `POST /v1/completions`, `GET /v1/models`, plus `GET /healthz` for the ALB health check |
| Authentication | The Cognito access token must have a valid RS256 signature, the right `iss`, an unexpired `exp`, `token_use=access`, and the required scope. Signing keys come from PyJWT's `PyJWKClient` (cached). An unreachable JWKS endpoint returns `503` |
| Cell selection | `int(sha256(session-id)) mod N`, over the cell order in the `router-cells` ConfigMap. Append new cells at the end. Changing the list remaps some sessions, which then start cold in their new cell |
| Proxying | Raw bytes are passed through as they arrive, so SSE is not buffered. `Authorization` is not forwarded to cells. The router adds `x-served-region` and `x-served-cell` |

Run the tests:

```bash
cd router
python3 -m venv .venv && . .venv/bin/activate
pip install -e '.[test]'
pytest
```

The tests cover routing determinism (including independence from `PYTHONHASHSEED`), distribution across cells, authentication (including the `503` when the JWKS is unreachable), the `400` cases, SSE pass-through and response headers.

## Later phases need configuration changes only

- **Phase 2 (P5 + vLLM):** set `inference_instance_type` of each cell to a P5 type in `terraform.tfvars`. The cell module reads the instance's EFA and network-card limits and outputs the matching EFA-only interface layout for the EC2NodeClass. Then put a vLLM worker in place of the mocker component (`workloads/vllm/`).
- **Phase 5 (second Region):** copy `infra/envs/region/` to a new directory with its own `terraform.tfvars` and the same `api_hostname`. Its Route 53 record joins the latency-based record set. To run the scripts against it, set `ENV_DIR=infra/envs/<new-dir>`.

## Pinned versions

| Component | Version | Pinned in |
|---|---|---|
| Terraform | 1.17.x | `infra/envs/region/versions.tf` |
| Terraform providers | `hashicorp/aws` 6.72.0 and others | `infra/envs/region/versions.tf`, `infra/envs/region/.terraform.lock.hcl` |
| Terraform modules | `terraform-aws-modules`: vpc 6.7.3, eks 21.29.0, eks-pod-identity 2.10.0 | the module sources |
| Kubernetes, EKS add-ons, AL2023 AMI release (system nodes, and Karpenter nodes as `al2023@v<date>`) | 1.37, AMI `1.37.1-20261031` | `infra/envs/region/variables.tf` |
| Helm charts and images | LBC 3.6.2, Karpenter 1.15.1, EFA plugin v0.5.35, Dynamo 1.6.1, `dynamo-planner` by digest | `scripts/versions.env` |
| SOCI snapshotter on inference nodes | the version shipped in the pinned AMI | AMI release above |
| Router base image | `python:3.13.18-slim-trixie` by digest | `router/Dockerfile` |
| Router Python dependencies | exact versions | `router/pyproject.toml` |

## Notes

- **Logs and metrics:** only the default CloudWatch integration is used: EKS control-plane logs plus the EC2, ALB and NLB metrics.
- **IAM:** in-cluster controllers (Karpenter, Load Balancer Controller) get credentials through EKS Pod Identity associations created by Terraform. The clusters have no OIDC provider.
- **Downloads at startup:** nodes download nothing at boot. The mocker downloads its tokenizer (`Qwen/Qwen3-0.6B`) from Hugging Face at startup.
- **Dynamo frontends:** each cell runs two frontend replicas. Each one subscribes to the workers' KV events itself (event plane, ZMQ by default), so both build the same prefix index. `DYN_ROUTER_REPLICA_SYNC=true` also shares active-request load between them.
- **No NATS or etcd:** Dynamo 1.6.1 discovers workers through the Kubernetes API, sends requests over TCP and KV events over ZMQ, so the platform chart installs only the operator. NATS would only be needed for `DYN_EVENT_PLANE=nats`, `DYN_REQUEST_PLANE=nats` or a NATS request-trace sink.
- **EFA device plugin image:** the plugin image comes from the EKS add-on registry of the Region, account `602401143452`. Opt-in Regions use a different account; set `EKS_ADDON_REGISTRY_ACCOUNT` in `scripts/versions.env`.

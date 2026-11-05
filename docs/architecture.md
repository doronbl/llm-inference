# Cell-Based LLM Inference Platform on Amazon EKS — Architecture Snapshot

**Status:** v1 (stub phase)
**Purpose:** Self-learning and experimentation platform for serving open-weight LLMs, built with a production-grade design.

---

## 1. Goals

- Serve open-weight LLMs through an **OpenAI-compatible HTTPS API** on a **single domain**.
- Use a **cell-based architecture**: each cell is an independent EKS cluster pinned to one Availability Zone.
- Keep routing **stateless and server-side**: any plain HTTP client (curl, any OpenAI-compatible SDK) that sends the required `session-id` header and a valid access token is routed correctly with no client-side routing logic.
- **Pin each session to one cell** so its KV cache is reused.
- Start in **one AWS Region** (configurable) with multiple cells. Adding Regions later must only require new configuration, not changes to the design.
- First milestone: a **stub deployment that works end to end** on CPU instances (no GPUs).

---

## 2. High-Level Architecture

```
Client (standard HTTP / OpenAI-compatible SDK)
   │   https://<api_hostname>/v1/...
   │   Authorization: Bearer <Cognito access token (JWT)>
   │   session-id: <conversation id>
   ▼
Route 53 (latency-based alias record in an existing public hosted zone)
   │
   ▼
Public ALB (TLS via ACM, JWT verification against Cognito)
   │
   ▼
Regional Router cluster (1 EKS cluster per Region)
   │   - cell = sha256(session-id) mod N_cells
   ▼
Cell k (1 EKS cluster, 1 AZ), reached through an internal NLB
   │   NVIDIA Dynamo frontend (OpenAI API) + KV Router
   ▼
Dynamo workers on Karpenter inference nodes (Dynamo mocker in v1, vLLM later)
```

### 2.1 Routing hierarchy

| Tier | Decides | Where it runs | Mechanism |
|---|---|---|---|
| 1. Region | Which Region | Route 53 | Latency-based routing on the single domain |
| 2. Cell | Which cell in the Region | Regional router cluster | `sha256(session-id) mod N_cells` |
| 3. Worker | Which worker in the cell | Inside each cell cluster | NVIDIA Dynamo KV Router (KV-cache-aware) |

### 2.2 Session pinning (tier 2)

1. The client **must** send a `session-id` header that identifies the conversation. Each session is pinned to one cell.
2. `cell_index = sha256(session-id) mod N_cells`. The list of cells is static configuration (a ConfigMap of the router; the list order defines the cell indexes).
3. Different sessions from the same client are spread across cells. Client identity is never part of the routing key.
4. If the `session-id` header is missing or empty, the router rejects the request with `400 Bad Request` and an OpenAI-format error body (`{"error": {"message": "...", "type": "invalid_request_error", "code": "missing_session_id"}}`).

### 2.3 Routing rules

- A request is always served in the Region it entered. Requests never travel between Regions.
- The KV cache never leaves its cell.
- If a request arrives in a Region or cell that doesn't hold its KV cache (a Region change, failover, or cache expiry), it is treated as **cold** and prefilled locally.
- The client holds no routing state: no cookies or Region-specific hostnames.

---

## 3. Authentication and Entry Point

- **Identity provider:** Amazon Cognito user pool with an app client using the **OAuth 2.0 client-credentials grant** (machine-to-machine). Clients obtain an access token (JWT) from the Cognito token endpoint.
- **No interactive login:** the Cognito hosted UI / managed login pages are not used. The Cognito domain exists only to serve the OAuth 2.0 token endpoint. The app client enables only the client-credentials flow (no authorization-code or implicit flow, no callback URLs).
- **Enforcement:** the public ALB verifies the JWT (signature via the user pool JWKS, issuer, expiry, `token_use = access`, required scope) before forwarding. Requests without a valid token are rejected at the ALB and never reach the cluster.
- **Client usage:** the access token is passed as the bearer token. With the OpenAI SDK, `api_key = <access token>`.
- **Defense in depth:** the router also validates the JWT (signature, issuer, expiry, `token_use`, scope) using the Cognito JWKS.
- **No** plain HTTP listener (port 80 is not opened) and **no** static API keys or basic auth.
- **TLS:** ACM public certificate for `<api_hostname>`, DNS-validated in the existing hosted zone. TLS 1.2+ security policy.

---

## 4. Cluster Roles

| Cluster | Count | Runs |
|---|---|---|
| **Regional router cluster** | 1 per Region | Regional router service (tier 2: cell selection, JWT check) |
| **Cell cluster** | N per Region, 1 per AZ | Dynamo platform, Dynamo frontend + KV Router (tier 3), and the workers it routes to |

The Dynamo frontend and KV Router always run in the same cluster as the workers they route to.

All EKS API endpoints are **private only**. Operators reach them from inside the VPC (operator-managed SSM Session Manager tunnel; the operator instance is created manually and is not part of this repository).

All clusters share one set of EKS settings (a thin Terraform `eks-base` wrapper around `terraform-aws-modules/eks`): private endpoint, EKS access entries, pinned add-ons, and the system managed node group.

---

## 5. Cell Definition

- **1 cell = 1 EKS cluster in 1 AZ.**
- Cells are identical. They are created from one reusable Terraform `cell` module with these inputs: `region`, `availability_zone`, `cell_id`, `inference_instance_type`, `efa_enabled`.
- Each cell contains:
  - **System node group:** EKS managed node group, latest-generation x86 `c` instances, EKS-optimized AL2023 AMI. Runs cluster add-ons, Karpenter, AWS Load Balancer Controller, and the Dynamo platform (operator, frontend, KV Router). Dynamo uses its defaults: Kubernetes-native worker discovery, TCP request plane, and ZMQ event plane for KV events. No etcd and no NATS. Frontend replicas run with router replica sync enabled.
  - **Karpenter inference nodes:** a Karpenter NodePool pinned to the cell's AZ, EKS-optimized AL2023 AMI, running all inference workers. Instance type is a parameter: `c8i.48xlarge` (CPU, EFA-capable) in v1, P5 family later. The inference EC2NodeClass and NodePool are rendered by the Terraform `cell` module. They use the same pinned AMI release as the system node groups (as the Karpenter alias `al2023@v<date>`).
  - **Inference workers:** aggregated serving, with prefill and decode in the same worker (Dynamo component type `worker`).

---

## 6. Networking

- **One VPC per Region**, shared by the regional router cluster and all cells. The router reaches the internal cell NLBs directly (no peering).
- Address space sized for dense pod IP allocation and EFA nodes:
  - VPC CIDR `/16` (configurable).
  - **Private subnets: `/18` per AZ** for nodes and pods.
  - Public subnets: `/24` per AZ (ALB and NAT gateways only).
  - Subnets in at least the cell AZs, and at least two AZs for EKS control planes and the ALB.
- **NAT gateway** per used AZ for outbound image/model pulls. VPC endpoints for ECR (api, dkr), S3 (gateway), STS, EC2, SSM, ssmmessages, ec2messages, EKS, EKS Auth (Pod Identity). Interface endpoints are placed in the cell AZs only.
- **Pod networking:** Amazon VPC CNI with **prefix delegation** enabled. Pod IPs come only from the primary (ENA) network interfaces.
- **EFA on inference nodes:** the primary network interface (network card 0, device index 0) is an ENA interface carrying IPv4 node and pod traffic. All additional interfaces are **EFA-only** interfaces (no IP addresses, RDMA only), up to the instance type's maximum. For `c8i.48xlarge` this is one EFA-only interface (network card 0, device index 1). Interfaces are configured through Karpenter `EC2NodeClass.networkInterfaces`. EFA devices are exposed to pods through the **EFA Kubernetes device plugin** as the `vpc.amazonaws.com/efa` resource. Inference nodes run in a **cluster placement group** per cell (Karpenter `placementGroupSelector`). Security group allows all traffic to and from itself (EFA requirement).
- **IAM for in-cluster controllers:** EKS Pod Identity (`eks-pod-identity-agent` add-on on every cluster). No IRSA / OIDC trust policies.
- **Load balancers:**
  - Public ALB, its listener, ACM certificate, JWT verification rule, and target group are created by **Terraform**. Router pods are registered into the target group by the **AWS Load Balancer Controller** via `TargetGroupBinding` (IP targets).
  - Internal NLB per cell is created by the **AWS Load Balancer Controller** from a Kubernetes `Service` of type `LoadBalancer` (internal, IP targets) in front of the Dynamo frontend. It is a separate Service because the Service the Dynamo operator creates for the frontend is always ClusterIP.
  - ALB idle timeout 3600 s to support long SSE streams.

---

## 7. API Contract

- **OpenAI-compatible** endpoints (served by the Dynamo frontend, proxied by the router):
  - `POST /v1/chat/completions` (streaming over SSE, and non-streaming)
  - `POST /v1/completions`
  - `GET /v1/models`
- **Authentication:** `Authorization: Bearer <Cognito access token>`.
- **Session header:** `session-id` (**required** on `POST` endpoints; identifies the conversation; used for cell pinning). Missing → `400`. Not required on `GET /v1/models`.
- **Response headers (for debugging):** `x-served-region`, `x-served-cell`.

---

## 8. Technology Stack

| Layer | Technology |
|---|---|
| DNS | Amazon Route 53 (latency-based alias record in an existing public hosted zone) |
| TLS | AWS Certificate Manager (DNS validation) |
| Authentication | Amazon Cognito (client-credentials grant), JWT verified at the ALB and in the router |
| Public entry point | Application Load Balancer (HTTPS only) |
| Load balancer integration | AWS Load Balancer Controller (`TargetGroupBinding` for the ALB, `Service` for internal NLBs) |
| Regional router | Small stateless Python service (FastAPI + uvicorn, httpx for streaming proxy, PyJWT for JWT verification) |
| Cell orchestration and worker routing | NVIDIA Dynamo 1.6.1 (operator, frontend, KV Router; Kubernetes discovery, TCP request plane, ZMQ event plane; no etcd, no NATS), installed with the Dynamo Helm charts |
| Stub engine (v1) | Dynamo mocker engine, deployed as a `DynamoGraphDeployment`; tokenizer `Qwen/Qwen3-0.6B` fetched from Hugging Face at startup |
| Inference engine (later) | vLLM, as a Dynamo worker |
| Kubernetes | Amazon EKS (private endpoints): one regional router cluster per Region, one cluster per cell |
| EKS node OS | EKS-optimized Amazon Linux 2023 AMIs |
| Non-EKS EC2 instances | Ubuntu Server 26.04 LTS |
| Node provisioning | Karpenter (AZ-pinned inference NodePool), EKS managed node group for system nodes |
| Controller IAM | EKS Pod Identity |
| Inference instances | Parameterized: `c8i.48xlarge` with EFA in v1, P5 family later |
| RDMA | EFA (EFA-only secondary interfaces) + EFA Kubernetes device plugin |
| Pod networking | Amazon VPC CNI with prefix delegation |
| Model storage | Amazon S3 (source of truth) — used from Phase 2 |
| Model loading | Run:ai Model Streamer (from S3) — used from Phase 2 |
| Container image loading | SOCI snapshotter on Karpenter inference nodes only (enabled in Phase 1): the AL2023 AMI's built-in snapshotter, enabled with the nodeadm `FastImagePull` feature gate and switched from parallel pull to lazy loading. A SOCI index is built on the operator host with the `soci` CLI only for the `dynamo-planner` mirror |
| Container registry | Amazon ECR: `router` repo (plain image) and a `dynamo-planner` mirror repo (with SOCI index) |
| Infrastructure as code | Terraform, local state |
| Logs and metrics | Amazon CloudWatch (default EKS/EC2/ALB/NLB integration only) |
| Deployment | Manual: Terraform from the operator host; Helm/`kubectl` through the SSM tunnel |

---

## 9. Configuration and Secrets

- Environment-specific values are **input variables only**: `region`, `hosted_zone_name`, `api_hostname`, `vpc_cidr`, cell list, instance types. The Cognito domain is a fixed prefix plus a generated random suffix.
- No domain names, hosted zone IDs, account IDs, or other environment details are committed to the repository.
- Values are supplied in a `terraform.tfvars` file that is git-ignored. The repository includes `terraform.tfvars.example` with placeholder values only.
- Cognito client secrets are output as sensitive Terraform outputs and never written to the repository.

---

## 10. Repository Layout (monorepo)

```
/
├── docs/
│   └── architecture.md            # this document
├── infra/                         # Terraform
│   ├── modules/
│   │   ├── network/               # VPC, subnets, NAT, VPC endpoints
│   │   ├── edge/                  # ACM, Cognito, public ALB, Route 53 record
│   │   ├── eks-base/              # shared EKS settings for every cluster (wrapper around terraform-aws-modules/eks)
│   │   ├── regional/              # regional router EKS cluster, ECR repos (router, dynamo-planner mirror)
│   │   └── cell/                  # one EKS cluster in one AZ + Karpenter + placement group; renders the inference EC2NodeClass and NodePool
│   └── envs/
│       └── region/                # one env per Region; lists cells
│           └── terraform.tfvars.example
├── platform/                      # per-cluster add-ons (Helm values/manifests)
│   ├── aws-load-balancer-controller/
│   ├── karpenter/                 # Helm values + EC2NodeClass (AL2023, SOCI, EFA) and inference NodePool templates
│   ├── efa-device-plugin/
│   ├── dynamo/
│   └── soci/                      # nodeadm FastImagePull config + lazy-loading switch (inference nodes)
├── router/                        # regional router service (Python)
│   ├── app/
│   ├── tests/
│   ├── pyproject.toml
│   ├── Dockerfile
│   └── deploy/                    # Kubernetes manifests incl. TargetGroupBinding
├── workloads/
│   ├── stub-engine/               # DynamoGraphDeployment for the Dynamo mocker + internal NLB Service
│   └── vllm/                      # real engine deployment (post-stub)
└── scripts/                       # manual deploy scripts: image build/mirror + SOCI index, add-ons, workloads, verification, teardown
```

---

## 11. Stub Milestone: Definition of Done

1. `terraform apply` for one Region creates: VPC, ACM certificate, Cognito user pool and app client, public ALB, Route 53 record, ECR repositories, the regional router cluster, and **two cells** in two different AZs.
2. The Dynamo mocker runs on Karpenter inference nodes (`c8i.48xlarge`, EFA interfaces attached and visible as `vpc.amazonaws.com/efa` on the node) in each cell, behind the Dynamo frontend.
3. SOCI is active on the inference nodes: the mocker pod's image (from the ECR `dynamo-planner` mirror with a SOCI index) is lazy-loaded, verified with `findmnt --source soci` on the node through SSM.
4. `curl https://<api_hostname>/v1/chat/completions` with a valid Cognito access token and `"stream": true` returns OpenAI-format SSE chunks ending with `data: [DONE]`.
5. Repeated requests with the same `session-id` always return the same `x-served-cell`.
6. Requests with different `session-id` values are spread across both cells.
7. The official OpenAI Python SDK works against the endpoint with `base_url`, `api_key = <access token>`, and `session-id` sent through `default_headers`.
8. A `POST` request without `session-id` returns `400` with an OpenAI-format error body.
9. A request without a valid token is rejected with `401`, and port 80 is not reachable.

---

## 12. Build Phases

| Phase | Scope |
|---|---|
| 1 | Stub milestone (section 11), including a teardown script |
| 2 | Switch the inference NodePool to a P5 instance and replace the mocker with vLLM, using a small dense open-weight model (~8B) loaded from S3 with Run:ai Model Streamer (no Hugging Face fetch at runtime) |
| 3 | Measure baseline TTFT, TPOT and cold-start time for each cell |
| 4 | Larger or MoE open-weight model |
| 5 | Add a second Region (copy `infra/envs/region/` to a new env directory + Route 53 latency record) |

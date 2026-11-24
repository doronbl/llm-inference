# vLLM engine (Phase 2)

`dynamographdeployment.yaml.tpl` replaces the Dynamo mocker of
`workloads/stub-engine/` with real inference. `scripts/50-engine.sh` deploys it
(it is the default engine, `ENGINE=vllm`).

| Component | Runs on | Details |
|---|---|---|
| `Frontend` (2 replicas) | system node group | Dynamo frontend (OpenAI Responses API), `DYN_ROUTER_MODE=round-robin` |
| `worker` (8 replicas) | one `p5en.48xlarge` Spot node (8 x H200) | `python3 -m dynamo.vllm --model Qwen/Qwen3-30B-A3B`, one GPU each |

- **Image:** `nvcr.io/nvidia/ai-dynamo/vllm-runtime:1.6.1`, pinned by digest in
  `scripts/versions.env` (vLLM 0.31.0; the Run:ai Model Streamer is included).
  The node pulls it from NGC with SOCI parallel pull.
- **Model:** each worker downloads `Qwen/Qwen3-30B-A3B` (about 57 GiB in BF16)
  from Hugging Face into its own `emptyDir`, which is on the node's
  instance-store RAID0. A new node therefore downloads 8 copies, about 460 GB
  through the NAT gateway. An optional `hf-token-secret` (key `HF_TOKEN`) in
  the `llm-inference` namespace raises the Hugging Face rate limits.
- **GPUs:** the NVIDIA device plugin (`platform/nvidia-device-plugin/`)
  advertises `nvidia.com/gpu`; the NVIDIA variant of the AL2023 AMI provides
  the driver and container runtime.
- **Probes and shared memory:** added by the Dynamo operator (startup probe of
  up to 2 hours, 8 GiB `/dev/shm`).
- **First start:** Spot launch, about 10 GB image pull, 8 parallel model
  downloads, then vLLM load and compile. Expect roughly 15-30 minutes.

## Later

- KV-cache-aware routing: `DYN_ROUTER_MODE=kv` plus the commented
  `--kv-events-config` worker argument.
- Download once per node instead of once per worker, or load from S3 with the
  Run:ai Model Streamer (`--load-format runai_streamer`).

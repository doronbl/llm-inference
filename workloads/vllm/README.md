# vLLM workers (Phase 2, not implemented)

Phase 2 replaces the Dynamo mocker in `workloads/stub-engine/` with vLLM
running as a Dynamo worker. The plan from `docs/architecture.md`:

- Set `inference_instance_type` of each cell to a P5 instance (Terraform
  computes the EFA-only interface layout for it).
- Serve a small dense open-weight model (about 8B) loaded from Amazon S3 with
  Run:ai Model Streamer; no Hugging Face fetch at runtime.
- Keep aggregated serving and the KV Router in KV mode.

This directory stays empty until then.

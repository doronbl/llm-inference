# Phase 2 engine: Dynamo frontend (OpenAI API, round-robin router) and eight
# vLLM workers, one per GPU of a p5en.48xlarge, aggregated serving (prefill and
# decode in the same worker). Rendered per cell by scripts/50-engine.sh with
# ENGINE=vllm (envsubst: DYNAMO_IMAGE VLLM_RUNTIME_IMAGE VLLM_MODEL).
#
#   DYNAMO_IMAGE        ECR mirror of dynamo-planner (frontend), as in Phase 1
#   VLLM_RUNTIME_IMAGE  nvcr.io/nvidia/ai-dynamo/vllm-runtime, pinned by digest
#   VLLM_MODEL          Hugging Face model id (Qwen/Qwen3-30B-A3B)
apiVersion: nvidia.com/v1beta1
kind: DynamoGraphDeployment
metadata:
  name: vllm-engine
  namespace: llm-inference
spec:
  components:
    # Frontend + router: system node group. round-robin sends each request to
    # the next worker in turn. To switch to KV-cache-aware routing, set
    # DYN_ROUTER_MODE to kv and add --kv-events-config to the worker args
    # (see the comment there); DYN_ROUTER_REPLICA_SYNC only matters in kv mode.
    - name: Frontend
      type: frontend
      replicas: 2
      podTemplate:
        spec:
          nodeSelector:
            llm-inference/node-class: system
          containers:
            - name: main
              image: ${DYNAMO_IMAGE}
              env:
                - name: DYN_ROUTER_MODE
                  value: round-robin
                - name: DYN_ROUTER_REPLICA_SYNC
                  value: "true"
              resources:
                requests:
                  cpu: "1"
                  memory: 4Gi
                limits:
                  memory: 8Gi

    # vLLM workers: Karpenter inference node (p5en.48xlarge Spot). Each worker
    # holds one H200 and downloads the model from Hugging Face into its own
    # emptyDir; the emptyDir lives on the node's instance-store RAID0
    # (EC2NodeClass instanceStorePolicy: RAID0). Eight workers download eight
    # copies (8 x ~57 GiB) at the same time on every new node.
    #
    # The Dynamo operator adds the probes (startup probe up to 2 h, which covers
    # the download) and an 8 GiB /dev/shm volume.
    - name: worker
      type: worker
      replicas: 8
      podTemplate:
        spec:
          nodeSelector:
            llm-inference/node-class: inference
          tolerations:
            - key: llm-inference/inference
              operator: Equal
              value: "true"
              effect: NoSchedule
          volumes:
            - name: model-cache
              emptyDir:
                sizeLimit: 100Gi
          containers:
            - name: main
              image: ${VLLM_RUNTIME_IMAGE}
              command: ["python3", "-m", "dynamo.vllm"]
              args:
                - --model
                - ${VLLM_MODEL}
                # For DYN_ROUTER_MODE=kv, publish KV cache events to the router:
                # - --kv-events-config
                # - '{"publisher":"zmq","topic":"kv-events","endpoint":"tcp://*:20080","enable_kv_cache_events":true}'
              env:
                - name: HF_HOME
                  value: /models/hf
              # Optional Hugging Face token (higher download rate limits):
              #   kubectl -n llm-inference create secret generic hf-token-secret --from-literal=HF_TOKEN=<token>
              envFrom:
                - secretRef:
                    name: hf-token-secret
                    optional: true
              volumeMounts:
                - name: model-cache
                  mountPath: /models
              resources:
                requests:
                  nvidia.com/gpu: "1"
                  # A p5en.48xlarge has 192 vCPUs and 2 TiB of memory; eight
                  # workers take a bit less than an eighth each.
                  cpu: "20"
                  memory: 200Gi
                  ephemeral-storage: 100Gi
                limits:
                  nvidia.com/gpu: "1"
                  memory: 240Gi
                  ephemeral-storage: 120Gi

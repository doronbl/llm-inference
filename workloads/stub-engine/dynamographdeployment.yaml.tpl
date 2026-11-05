# Stub engine for Phase 1: Dynamo frontend (OpenAI API + KV Router) and Dynamo
# mocker workers, aggregated serving (prefill and decode in the same worker).
# Rendered per cell by scripts/50-stub-engine.sh (envsubst: DYNAMO_IMAGE).
#
# DYNAMO_IMAGE is the ECR mirror of nvcr.io/nvidia/ai-dynamo/dynamo-planner
# with a SOCI index (the mocker ships in the planner image).
apiVersion: nvidia.com/v1beta1
kind: DynamoGraphDeployment
metadata:
  name: stub-engine
  namespace: llm-inference
spec:
  components:
    # Frontend + KV Router: system node group. Each replica subscribes to the
    # workers' KV events itself (event plane, ZMQ by default), so both build
    # the same prefix index. Replica sync also shares active-request load.
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
                  value: kv
                - name: DYN_ROUTER_REPLICA_SYNC
                  value: "true"
              resources:
                requests:
                  cpu: "1"
                  memory: 4Gi
                limits:
                  memory: 8Gi

    # Mocker workers: Karpenter inference nodes (AZ-pinned NodePool).
    # "worker" is the aggregated component type; the mocker defaults to
    # --disaggregation-mode agg and publishes KV events.
    - name: worker
      type: worker
      replicas: 2
      podTemplate:
        spec:
          nodeSelector:
            llm-inference/node-class: inference
          tolerations:
            - key: llm-inference/inference
              operator: Equal
              value: "true"
              effect: NoSchedule
          containers:
            - name: main
              image: ${DYNAMO_IMAGE}
              workingDir: /workspace
              command: ["python3", "-m", "dynamo.mocker"]
              args:
                # Tokenizer only; fetched from Hugging Face at startup.
                - --model-path
                - Qwen/Qwen3-0.6B
                - --model-name
                - Qwen/Qwen3-0.6B
              resources:
                requests:
                  cpu: "8"
                  memory: 16Gi
                limits:
                  memory: 32Gi

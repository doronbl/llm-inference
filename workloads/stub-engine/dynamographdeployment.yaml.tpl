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
    # Frontend + KV Router: system node group.
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
              resources:
                requests:
                  cpu: "1"
                  memory: 4Gi
                limits:
                  memory: 8Gi

    # Mocker workers: Karpenter inference nodes (AZ-pinned NodePool).
    # The mocker publishes KV events, so the frontend routes on real cache state.
    - name: decode
      type: decode
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

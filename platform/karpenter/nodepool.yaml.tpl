# Inference NodePool, one per cell, pinned to the cell's Availability Zone.
# Rendered by scripts/41-platform-cells.sh (envsubst).
#
# Only inference workers run here: the taint keeps everything else on the
# system node group. The instance type comes from the cell module input
# inference_instance_type (c8i.48xlarge in Phase 1, P5 later).
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: inference
spec:
  template:
    metadata:
      labels:
        llm-inference/node-class: inference
        llm-inference/cell: "${CELL_ID}"
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: inference
      requirements:
        - key: topology.kubernetes.io/zone
          operator: In
          values: ["${AVAILABILITY_ZONE}"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["${INFERENCE_INSTANCE_TYPE}"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
      taints:
        - key: llm-inference/inference
          value: "true"
          effect: NoSchedule
      expireAfter: 720h
  limits:
    # Upper bound on inference capacity per cell (vCPUs across all nodes).
    cpu: "${INFERENCE_CPU_LIMIT}"
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 10m

# Inference EC2NodeClass, one per cell. Rendered by scripts/41-platform-cells.sh
# (envsubst) from Terraform outputs of the cell module.
#
#   - EKS-optimized AL2023 AMI (pinned alias)
#   - the cell's single private subnet (AZ-pinned)
#   - node security group + self-referencing EFA security group
#   - cluster placement group of the cell
#   - EFA-only secondary interfaces (omitted when efa_enabled = false)
#   - SOCI snapshotter (platform/soci/) through MIME user data, merged by
#     nodeadm with the NodeConfig Karpenter generates
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: inference
spec:
  role: ${KARPENTER_NODE_ROLE}
  amiSelectorTerms:
    - alias: ${AL2023_AMI_ALIAS}
  subnetSelectorTerms:
    - id: ${CELL_SUBNET_ID}
  securityGroupSelectorTerms:
    - id: ${NODE_SECURITY_GROUP_ID}
    - id: ${EFA_SECURITY_GROUP_ID}
  placementGroupSelector:
    name: ${PLACEMENT_GROUP_NAME}
${NETWORK_INTERFACES_BLOCK}
  kubelet:
    maxPods: 110
  metadataOptions:
    httpEndpoint: enabled
    httpTokens: required
    httpPutResponseHopLimit: 1
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 300Gi
        volumeType: gp3
        iops: 16000
        throughput: 1000
        encrypted: true
        deleteOnTermination: true
  tags:
    llm-inference/cell: "${CELL_ID}"
  userData: |
${SOCI_USER_DATA}

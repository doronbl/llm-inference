#!/usr/bin/env bash
# Step 5: add-ons on every cell cluster:
#   AWS Load Balancer Controller, Karpenter (+ inference EC2NodeClass and
#   NodePool), EFA device plugin, Dynamo platform (operator + NATS).
# Requires the tunnels from scripts/20-tunnels.sh.
source "$(dirname "$0")/lib.sh"
require helm kubectl jq envsubst

REGION="$(region)"
VPC_ID="$(tf_deploy '.vpc_id')"

helm repo add eks https://aws.github.io/eks-charts --force-update >/dev/null

# MIME multipart user data for the EC2NodeClass: the same SOCI install script
# and NodeConfig fragment the managed node groups get from Terraform.
soci_user_data() {
  cat <<EOF
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="//"

--//
Content-Type: text/x-shellscript; charset="us-ascii"

$(cat "${REPO_ROOT}/platform/soci/install-soci.sh")

--//
Content-Type: application/node.eks.aws

$(cat "${REPO_ROOT}/platform/soci/nodeconfig.yaml")

--//--
EOF
}

for id in $(cell_ids); do
  CTX="$(cell_cluster "${id}")"
  log "Cell ${id} (${CTX})"

  # AWS Load Balancer Controller -----------------------------------------------
  hc "${CTX}" upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
    --version "${LBC_CHART_VERSION}" \
    --namespace kube-system \
    --values "${REPO_ROOT}/platform/aws-load-balancer-controller/values.yaml" \
    --set clusterName="${CTX}" \
    --set region="${REGION}" \
    --set vpcId="${VPC_ID}" \
    --set-string "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$(cell_value "${id}" lbc_role_arn)" \
    --wait --timeout 10m
  ok "aws-load-balancer-controller"

  # Karpenter ------------------------------------------------------------------
  hc "${CTX}" upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
    --version "${KARPENTER_VERSION}" \
    --namespace kube-system \
    --values "${REPO_ROOT}/platform/karpenter/values.yaml" \
    --set settings.clusterName="${CTX}" \
    --set settings.clusterEndpoint="$(cell_value "${id}" cluster_endpoint)" \
    --set settings.interruptionQueue="$(cell_value "${id}" karpenter_interruption_queue)" \
    --set-string "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$(cell_value "${id}" karpenter_controller_role_arn)" \
    --wait --timeout 10m
  ok "karpenter"

  export CELL_ID="${id}"
  export AVAILABILITY_ZONE; AVAILABILITY_ZONE="$(cell_value "${id}" availability_zone)"
  export INFERENCE_INSTANCE_TYPE; INFERENCE_INSTANCE_TYPE="$(cell_value "${id}" inference_instance_type)"
  export KARPENTER_NODE_ROLE; KARPENTER_NODE_ROLE="$(cell_value "${id}" karpenter_node_role_name)"
  export CELL_SUBNET_ID; CELL_SUBNET_ID="$(cell_value "${id}" subnet_id)"
  export NODE_SECURITY_GROUP_ID; NODE_SECURITY_GROUP_ID="$(cell_value "${id}" node_security_group_id)"
  export EFA_SECURITY_GROUP_ID; EFA_SECURITY_GROUP_ID="$(cell_value "${id}" efa_security_group_id)"
  export PLACEMENT_GROUP_NAME; PLACEMENT_GROUP_NAME="$(cell_value "${id}" placement_group_name)"
  export AL2023_AMI_ALIAS INFERENCE_CPU_LIMIT
  export SOCI_USER_DATA; SOCI_USER_DATA="$(soci_user_data | sed 's/^/    /')"
  if [[ "$(cell_value "${id}" efa_enabled)" == "true" ]]; then
    export NETWORK_INTERFACES_BLOCK; NETWORK_INTERFACES_BLOCK="  networkInterfaces: $(tf_deploy ".cells[\"${id}\"].inference_network_interfaces | tojson")"
  else
    export NETWORK_INTERFACES_BLOCK=""
  fi

  render "${REPO_ROOT}/platform/karpenter/ec2nodeclass.yaml.tpl" \
    KARPENTER_NODE_ROLE AL2023_AMI_ALIAS CELL_SUBNET_ID NODE_SECURITY_GROUP_ID EFA_SECURITY_GROUP_ID \
    PLACEMENT_GROUP_NAME NETWORK_INTERFACES_BLOCK CELL_ID SOCI_USER_DATA >"${STATE_DIR}/ec2nodeclass-${id}.yaml"
  render "${REPO_ROOT}/platform/karpenter/nodepool.yaml.tpl" \
    CELL_ID AVAILABILITY_ZONE INFERENCE_INSTANCE_TYPE INFERENCE_CPU_LIMIT >"${STATE_DIR}/nodepool-${id}.yaml"

  kc "${CTX}" apply -f "${STATE_DIR}/ec2nodeclass-${id}.yaml"
  kc "${CTX}" apply -f "${STATE_DIR}/nodepool-${id}.yaml"
  kc "${CTX}" wait --for=condition=Ready ec2nodeclass/inference --timeout=5m
  ok "inference EC2NodeClass + NodePool (${INFERENCE_INSTANCE_TYPE} in ${AVAILABILITY_ZONE}, $(cell_value "${id}" efa_interface_count) EFA-only interface(s))"

  # EFA device plugin ----------------------------------------------------------
  hc "${CTX}" upgrade --install aws-efa-k8s-device-plugin eks/aws-efa-k8s-device-plugin \
    --version "${EFA_PLUGIN_CHART_VERSION}" \
    --namespace kube-system \
    --values "${REPO_ROOT}/platform/efa-device-plugin/values.yaml" \
    --set image.repository="${EKS_ADDON_REGISTRY_ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/eks/aws-efa-k8s-device-plugin" \
    --wait --timeout 5m
  ok "aws-efa-k8s-device-plugin"

  # Dynamo platform ------------------------------------------------------------
  hc "${CTX}" upgrade --install dynamo-platform \
    "https://helm.ngc.nvidia.com/nvidia/ai-dynamo/charts/dynamo-platform-${DYNAMO_VERSION}.tgz" \
    --namespace dynamo-system --create-namespace \
    --values "${REPO_ROOT}/platform/dynamo/values.yaml" \
    --wait --timeout 15m
  ok "dynamo-platform ${DYNAMO_VERSION}"
done

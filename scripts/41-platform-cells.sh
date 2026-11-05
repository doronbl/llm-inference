#!/usr/bin/env bash
# Step 5: add-ons on every cell cluster:
#   AWS Load Balancer Controller, Karpenter (+ the inference EC2NodeClass and
#   NodePool rendered by Terraform), EFA device plugin, Dynamo platform
#   (operator only). IAM comes from EKS Pod Identity associations created by
#   Terraform, so no service-account annotations are set here.
# Requires the tunnels from scripts/20-tunnels.sh.
source "$(dirname "$0")/lib.sh"
require helm kubectl jq

REGION="$(region)"
VPC_ID="$(tf_deploy '.vpc_id')"

helm repo add eks https://aws.github.io/eks-charts --force-update >/dev/null

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
    --wait --timeout 10m
  ok "karpenter"

  # Inference EC2NodeClass + NodePool, rendered by infra/modules/cell.
  cell_value "${id}" karpenter_manifests | kc "${CTX}" apply -f -
  kc "${CTX}" wait --for=condition=Ready ec2nodeclass/inference --timeout=5m
  ok "inference EC2NodeClass + NodePool ($(cell_value "${id}" inference_instance_type) in $(cell_value "${id}" availability_zone), $(cell_value "${id}" efa_interface_count) EFA-only interface(s))"

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

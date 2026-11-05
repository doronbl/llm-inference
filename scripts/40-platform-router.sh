#!/usr/bin/env bash
# Step 4: add-ons on the regional router cluster (AWS Load Balancer Controller).
# IAM comes from the EKS Pod Identity association created by Terraform.
# Requires the tunnels from scripts/20-tunnels.sh.
source "$(dirname "$0")/lib.sh"
require helm kubectl jq

CTX="$(router_cluster)"

log "AWS Load Balancer Controller ${LBC_CHART_VERSION} on ${CTX}"
helm repo add eks https://aws.github.io/eks-charts --force-update >/dev/null
hc "${CTX}" upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --version "${LBC_CHART_VERSION}" \
  --namespace kube-system \
  --values "${REPO_ROOT}/platform/aws-load-balancer-controller/values.yaml" \
  --set clusterName="${CTX}" \
  --set region="$(region)" \
  --set vpcId="$(tf_deploy '.vpc_id')" \
  --wait --timeout 10m
ok "aws-load-balancer-controller ready"

#!/usr/bin/env bash
# Step 6: deploy the stub engine (Dynamo frontend + KV Router + mocker workers)
# and its internal NLB in every cell. The first deploy launches a Karpenter
# inference node per cell, which takes several minutes.
source "$(dirname "$0")/lib.sh"
require kubectl jq envsubst
image_env

export DYNAMO_IMAGE VPC_CIDR
VPC_CIDR="$(tf_deploy '.vpc_cidr')"

for id in $(cell_ids); do
  CTX="$(cell_cluster "${id}")"
  log "Cell ${id} (${CTX})"
  export CELL_ID="${id}"
  export CELL_SUBNET_ID; CELL_SUBNET_ID="$(cell_value "${id}" subnet_id)"

  kc "${CTX}" apply -f "${REPO_ROOT}/workloads/stub-engine/namespace.yaml"
  render "${REPO_ROOT}/workloads/stub-engine/dynamographdeployment.yaml.tpl" DYNAMO_IMAGE \
    | kc "${CTX}" apply -f -
  render "${REPO_ROOT}/workloads/stub-engine/frontend-nlb-service.yaml.tpl" CELL_SUBNET_ID CELL_ID VPC_CIDR \
    | kc "${CTX}" apply -f -
done

for id in $(cell_ids); do
  CTX="$(cell_cluster "${id}")"
  log "Waiting for cell ${id}"
  kc "${CTX}" -n llm-inference wait --for=condition=Ready dynamographdeployment/stub-engine --timeout=45m
  ok "stub-engine Ready"

  hostname=""
  for _ in $(seq 1 60); do
    hostname="$(kc "${CTX}" -n llm-inference get service frontend-nlb -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
    [[ -n "${hostname}" ]] && break
    sleep 10
  done
  [[ -n "${hostname}" ]] || die "cell ${id}: internal NLB has no hostname yet"
  echo "${hostname}" >"${STATE_DIR}/cell-${id}.nlb"
  ok "internal NLB ${hostname}"

  kc "${CTX}" get nodes -l llm-inference/node-class=inference \
    -o custom-columns='NODE:.metadata.name,TYPE:.metadata.labels.node\.kubernetes\.io/instance-type,ZONE:.metadata.labels.topology\.kubernetes\.io/zone,EFA:.status.allocatable.vpc\.amazonaws\.com/efa'
done

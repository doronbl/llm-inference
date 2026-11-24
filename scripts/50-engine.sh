#!/usr/bin/env bash
# Step 6: deploy the engine and its internal NLB in every cell.
#   ENGINE=vllm (default)  Dynamo frontend (round-robin) + 8 vLLM workers on a
#                          GPU node (workloads/vllm/)
#   ENGINE=stub            Dynamo frontend (KV Router) + mocker workers on a
#                          CPU node (workloads/stub-engine/, Phase 1)
# The first deploy launches a Karpenter inference node per cell, which takes
# several minutes (vllm: 15-30 minutes including the model download).
# Without ENGINE in the environment it reuses the engine recorded by the last
# run (${STATE_DIR}/engine), else vllm. Switching ENGINE deletes the other
# engine's DynamoGraphDeployment.
source "$(dirname "$0")/lib.sh"
require aws kubectl jq envsubst
image_env

export DYNAMO_IMAGE VLLM_RUNTIME_IMAGE VLLM_MODEL VPC_CIDR ENGINE_DGD
VPC_CIDR="$(tf_deploy '.vpc_cidr')"
log "Engine ${ENGINE} (${ENGINE_DGD})"

# The vLLM workers request nvidia.com/gpu: refuse cells whose inference
# instance type has no GPUs (their pods could never be scheduled).
if [[ "${ENGINE}" == "vllm" ]]; then
  for id in $(cell_ids); do
    type="$(cell_value "${id}" inference_instance_type)"
    gpus="$(aws ec2 describe-instance-types --region "$(region)" --instance-types "${type}" \
      --query 'InstanceTypes[0].GpuInfo.Gpus[0].Count' --output text)"
    [[ "${gpus}" =~ ^[0-9]+$ && "${gpus}" -ge 1 ]] \
      || die "cell ${id}: ${type} has no GPUs; ENGINE=vllm needs a GPU instance type (use ENGINE=stub for CPU cells)"
  done
fi
echo "${ENGINE}" >"${ENGINE_STATE_FILE}"

for id in $(cell_ids); do
  CTX="$(cell_cluster "${id}")"
  log "Cell ${id} (${CTX})"
  export CELL_ID="${id}"
  export CELL_SUBNET_ID; CELL_SUBNET_ID="$(cell_value "${id}" subnet_id)"

  kc "${CTX}" apply -f "${REPO_ROOT}/workloads/common/namespace.yaml"
  for dgd in ${ALL_ENGINE_DGDS}; do
    [[ "${dgd}" == "${ENGINE_DGD}" ]] && continue
    kc "${CTX}" -n llm-inference delete dynamographdeployment "${dgd}" --ignore-not-found --wait=true --timeout=10m
  done
  render "${ENGINE_DIR}/dynamographdeployment.yaml.tpl" DYNAMO_IMAGE VLLM_RUNTIME_IMAGE VLLM_MODEL \
    | kc "${CTX}" apply -f -
  render "${REPO_ROOT}/workloads/common/frontend-nlb-service.yaml.tpl" CELL_SUBNET_ID CELL_ID VPC_CIDR ENGINE_DGD \
    | kc "${CTX}" apply -f -
done

for id in $(cell_ids); do
  CTX="$(cell_cluster "${id}")"
  log "Waiting for cell ${id}"
  kc "${CTX}" -n llm-inference wait --for=condition=Ready "dynamographdeployment/${ENGINE_DGD}" \
    --timeout="${ENGINE_TIMEOUT:-${STUB_ENGINE_TIMEOUT:-45m}}"
  ok "${ENGINE_DGD} Ready"

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
    -o custom-columns='NODE:.metadata.name,TYPE:.metadata.labels.node\.kubernetes\.io/instance-type,CAPACITY:.metadata.labels.karpenter\.sh/capacity-type,ZONE:.metadata.labels.topology\.kubernetes\.io/zone,GPU:.status.allocatable.nvidia\.com/gpu,EFA:.status.allocatable.vpc\.amazonaws\.com/efa'
done

#!/usr/bin/env bash
# Teardown: remove everything this repository created in the Region.
#
# Resources created by in-cluster controllers (internal NLBs, Karpenter
# instances and instance profiles, ALB target registrations) are not in
# Terraform state, so they are deleted first, while the controllers still run.
# Then terraform destroy removes the rest.
#
# The operator instance (the SSM tunnel endpoint) lives in the Region VPC but
# is not in Terraform state, so the VPC cannot be deleted while it exists.
# After the in-cluster cleanup, the script terminates it and deletes its
# security groups if they are in this VPC and not managed by Terraform.
#
# Usage: OPERATOR_INSTANCE_ID=i-... scripts/90-teardown.sh [--yes]
source "$(dirname "$0")/lib.sh"
require terraform kubectl jq aws
: "${OPERATOR_INSTANCE_ID:?set OPERATOR_INSTANCE_ID to the operator EC2 instance ID}"

if [[ "${1:-}" == "--yes" ]]; then
  auto_approve=(-auto-approve)
else
  auto_approve=()
  echo "This destroys the whole Region environment in ${ENV_DIR} ($(region)),"
  echo "including the operator instance ${OPERATOR_INSTANCE_ID} if it is in the Region VPC."
  read -r -p "Type the Region name to continue: " answer
  [[ "${answer}" == "$(region)" ]] || die "aborted"
fi

REGION="$(region)"
VPC_ID="$(tf_deploy '.vpc_id')"

# Terminates the operator instance if it is in the Region VPC, then deletes
# its security groups that are in this VPC and not managed by Terraform.
remove_operator_instance() {
  local info vpc state sgs
  info="$(aws ec2 describe-instances --region "${REGION}" --instance-ids "${OPERATOR_INSTANCE_ID}" \
    --query 'Reservations[0].Instances[0]' --output json 2>/dev/null || echo null)"
  vpc="$(jq -r '.VpcId // ""' <<<"${info}")"
  state="$(jq -r '.State.Name // ""' <<<"${info}")"
  if [[ "${vpc}" != "${VPC_ID}" || "${state}" == "terminated" ]]; then
    ok "operator instance ${OPERATOR_INSTANCE_ID} is not running in ${VPC_ID}; nothing to remove"
    return 0
  fi
  sgs="$(jq -r '[.SecurityGroups[].GroupId] | join(" ")' <<<"${info}")"
  log "Terminating operator instance ${OPERATOR_INSTANCE_ID} (in ${VPC_ID})"
  aws ec2 terminate-instances --region "${REGION}" --instance-ids "${OPERATOR_INSTANCE_ID}" >/dev/null
  aws ec2 wait instance-terminated --region "${REGION}" --instance-ids "${OPERATOR_INSTANCE_ID}"
  ok "operator instance terminated"
  for sg in ${sgs}; do
    local sg_info
    sg_info="$(aws ec2 describe-security-groups --region "${REGION}" --group-ids "${sg}" \
      --query 'SecurityGroups[0].{vpc:VpcId,name:GroupName,managed:Tags[?Key==`ManagedBy`]|[0].Value}' --output json)"
    if [[ "$(jq -r .vpc <<<"${sg_info}")" == "${VPC_ID}" && "$(jq -r .name <<<"${sg_info}")" != "default" \
          && "$(jq -r '.managed // ""' <<<"${sg_info}")" != "terraform" ]]; then
      aws ec2 delete-security-group --region "${REGION}" --group-id "${sg}"
      ok "deleted security group ${sg} ($(jq -r .name <<<"${sg_info}"))"
    fi
  done
}

reachable() { kubectl --context "$1" version --request-timeout=5s >/dev/null 2>&1; }

"${SCRIPTS_DIR}/20-tunnels.sh" start || die "tunnels are required to clean up in-cluster resources"

ROUTER_CTX="$(router_cluster)"
if reachable "${ROUTER_CTX}"; then
  log "Router cluster: unbind the ALB target group"
  kc "${ROUTER_CTX}" -n llm-router delete targetgroupbinding router --ignore-not-found --wait=true --timeout=5m
  kc "${ROUTER_CTX}" delete namespace llm-router --ignore-not-found --wait=true --timeout=10m
fi

for id in $(cell_ids); do
  CTX="$(cell_cluster "${id}")"
  reachable "${CTX}" || { fail "cell ${id}: API not reachable, skipping in-cluster cleanup"; continue; }
  log "Cell ${id}: workloads, internal NLB and Karpenter nodes"
  kc "${CTX}" -n llm-inference delete dynamographdeployment stub-engine --ignore-not-found --wait=true --timeout=10m
  # Deleting the Service makes the controller delete the NLB and its security groups.
  kc "${CTX}" -n llm-inference delete service frontend-nlb --ignore-not-found --wait=true --timeout=10m
  # Deleting the NodePool terminates its instances; deleting the EC2NodeClass
  # removes the instance profile Karpenter created for the node role.
  kc "${CTX}" delete nodepool inference --ignore-not-found --wait=true --timeout=15m
  kc "${CTX}" delete ec2nodeclass inference --ignore-not-found --wait=true --timeout=10m
  for _ in $(seq 1 60); do
    [[ "$(kc "${CTX}" get nodeclaims --no-headers 2>/dev/null | wc -l)" -eq 0 ]] && break
    sleep 10
  done
  ok "cell ${id} cleaned"
done

"${SCRIPTS_DIR}/20-tunnels.sh" stop

remove_operator_instance

log "terraform destroy"
terraform -chdir="${ENV_DIR}" destroy -input=false "${auto_approve[@]}"
rm -f "${STATE_DIR}"/deploy.json "${STATE_DIR}"/cell-*.nlb "${STATE_DIR}"/images.env "${STATE_DIR}"/kubeconfig
ok "Region environment destroyed"

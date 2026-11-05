#!/usr/bin/env bash
# Teardown: remove everything this repository created in the Region.
#
# Resources created by in-cluster controllers (internal NLBs, Karpenter
# instances and instance profiles, ALB target registrations) are not in
# Terraform state, so they are deleted first, while the controllers still run.
# Then terraform destroy removes the rest.
#
# Usage: OPERATOR_INSTANCE_ID=i-... scripts/90-teardown.sh [--yes]
source "$(dirname "$0")/lib.sh"
require terraform kubectl jq aws

if [[ "${1:-}" != "--yes" ]]; then
  echo "This destroys the whole Region environment in ${ENV_DIR} ($(region))."
  read -r -p "Type the Region name to continue: " answer
  [[ "${answer}" == "$(region)" ]] || die "aborted"
fi

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

log "terraform destroy"
terraform -chdir="${ENV_DIR}" destroy -input=false
rm -f "${STATE_DIR}"/deploy.json "${STATE_DIR}"/cell-*.nlb
ok "Region environment destroyed"

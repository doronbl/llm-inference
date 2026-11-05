#!/usr/bin/env bash
# Step 7: deploy the regional router and bind it to the ALB target group.
# The cell list (id + internal NLB URL) comes from scripts/50-stub-engine.sh.
source "$(dirname "$0")/lib.sh"
require kubectl jq envsubst aws
image_env

CTX="$(router_cluster)"
REGION="$(region)"

cells_json="[]"
for id in $(cell_ids); do
  [[ -f "${STATE_DIR}/cell-${id}.nlb" ]] || die "no NLB for cell ${id}; run scripts/50-stub-engine.sh first"
  url="http://$(cat "${STATE_DIR}/cell-${id}.nlb"):8000"
  cells_json="$(jq -c --arg id "${id}" --arg url "${url}" '. + [{id: $id, url: $url}]' <<<"${cells_json}")"
done

export REGION ROUTER_IMAGE
export COGNITO_ISSUER; COGNITO_ISSUER="$(tf_deploy '.cognito.issuer')"
export COGNITO_JWKS_URL; COGNITO_JWKS_URL="$(tf_deploy '.cognito.jwks_url')"
export REQUIRED_SCOPE; REQUIRED_SCOPE="$(tf_deploy '.cognito.required_scope')"
export CELLS_JSON; CELLS_JSON="$(jq -c '{cells: .}' <<<"${cells_json}")"
export ROUTER_TARGET_GROUP_ARN; ROUTER_TARGET_GROUP_ARN="$(tf_deploy '.router.target_group_arn')"

log "Router ${ROUTER_IMAGE} on ${CTX}"
echo "cells: ${CELLS_JSON}"

D="${REPO_ROOT}/router/deploy"
kc "${CTX}" apply -f "${D}/namespace.yaml"
render "${D}/config.yaml.tpl" REGION COGNITO_ISSUER COGNITO_JWKS_URL REQUIRED_SCOPE CELLS_JSON | kc "${CTX}" apply -f -
kc "${CTX}" apply -f "${D}/service.yaml"
render "${D}/deployment.yaml.tpl" ROUTER_IMAGE | kc "${CTX}" apply -f -
render "${D}/targetgroupbinding.yaml.tpl" ROUTER_TARGET_GROUP_ARN | kc "${CTX}" apply -f -

# Config changes do not change the pod template; restart to pick them up.
kc "${CTX}" -n llm-router rollout restart deployment/router
kc "${CTX}" -n llm-router rollout status deployment/router --timeout=15m
ok "router rolled out"

log "ALB target health"
for _ in $(seq 1 30); do
  healthy="$(aws elbv2 describe-target-health --region "${REGION}" --target-group-arn "${ROUTER_TARGET_GROUP_ARN}" \
    --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text)"
  [[ "${healthy}" -ge 1 ]] && break
  sleep 10
done
aws elbv2 describe-target-health --region "${REGION}" --target-group-arn "${ROUTER_TARGET_GROUP_ARN}" \
  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output table
[[ "${healthy}" -ge 1 ]] || die "no healthy router targets"
ok "API: $(tf_deploy '.api_url')"

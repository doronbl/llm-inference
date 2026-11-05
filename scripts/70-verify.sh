#!/usr/bin/env bash
# Step 8: check every Definition of Done item (docs/architecture.md, section 11).
# Requires the tunnels from scripts/20-tunnels.sh (for DoD 2 and 3) and the
# openai package for DoD 7 (pip install openai==3.46.0).
source "$(dirname "$0")/lib.sh"
require terraform aws kubectl jq curl python3

REGION="$(region)"
HOST="$(tf_deploy '.api_hostname')"
API="https://${HOST}/v1"
failures=0
check() { if "$@"; then :; else failures=$((failures + 1)); fi; }

################################################################################
dod1() {
  log "DoD 1: terraform created VPC, ACM, Cognito, ALB, Route 53, ECR, router cluster and two cells"
  local state ok_all=0
  state="$(terraform -chdir="${ENV_DIR}" state list)"
  for addr in \
    'module.network.module.vpc.aws_vpc.this[0]' \
    'module.edge.aws_acm_certificate.api' \
    'module.edge.aws_cognito_user_pool.this' \
    'module.edge.aws_cognito_user_pool_client.m2m' \
    'module.edge.aws_lb.this' \
    'module.edge.aws_route53_record.api' \
    'module.regional.aws_ecr_repository.this["router"]' \
    'module.regional.aws_ecr_repository.this["dynamo-planner"]' \
    'module.regional.module.eks.aws_eks_cluster.this[0]'; do
    if grep -qxF "${addr}" <<<"${state}"; then ok "${addr}"; else fail "${addr} missing"; ok_all=1; fi
  done
  local azs
  azs="$(tf_deploy '[.cells[].availability_zone] | unique | length')"
  if [[ "$(tf_deploy '.cells | length')" -ge 2 && "${azs}" -ge 2 ]]; then
    ok "$(tf_deploy '.cells | length') cells in ${azs} AZs: $(tf_deploy '[.cells[] | "\(.cluster_name)@\(.availability_zone)"] | join(", ")')"
  else
    fail "need two cells in two different AZs"; ok_all=1
  fi
  return "${ok_all}"
}

################################################################################
dod2_3() {
  log "DoD 2: mocker on Karpenter inference nodes with EFA, behind the Dynamo frontend"
  log "DoD 3: SOCI lazy-loads the mocker image (findmnt --source soci via SSM)"
  local rc=0
  for id in $(cell_ids); do
    local ctx expected_type efa_expected nodes
    ctx="$(cell_cluster "${id}")"
    expected_type="$(cell_value "${id}" inference_instance_type)"
    efa_expected="$(cell_value "${id}" efa_interface_count)"

    nodes="$(kc "${ctx}" get pods -n llm-inference \
      -l nvidia.com/dynamo-graph-deployment-name=stub-engine,nvidia.com/dynamo-component-type=worker \
      --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u)"
    if [[ -z "${nodes}" ]]; then fail "cell ${id}: no running mocker pods"; rc=1; continue; fi

    for node in ${nodes}; do
      local info type nodepool efa provider instance
      info="$(kc "${ctx}" get node "${node}" -o json)"
      type="$(jq -r '.metadata.labels["node.kubernetes.io/instance-type"]' <<<"${info}")"
      nodepool="$(jq -r '.metadata.labels["karpenter.sh/nodepool"] // ""' <<<"${info}")"
      efa="$(jq -r '.status.allocatable["vpc.amazonaws.com/efa"] // "0"' <<<"${info}")"
      if [[ "${nodepool}" == "inference" && "${type}" == "${expected_type}" && "${efa}" -ge "${efa_expected}" && "${efa}" -ge 1 ]]; then
        ok "cell ${id}: mocker on ${node} (${type}, nodepool=${nodepool}, vpc.amazonaws.com/efa=${efa})"
      else
        fail "cell ${id}: ${node} type=${type} nodepool=${nodepool} efa=${efa} (want ${expected_type}, inference, >=${efa_expected})"; rc=1
      fi

      provider="$(jq -r '.spec.providerID' <<<"${info}")"
      instance="${provider##*/}"
      local cmd out
      cmd="$(aws ssm send-command --region "${REGION}" --instance-ids "${instance}" \
        --document-name AWS-RunShellScript --comment "DoD3 SOCI mounts" \
        --parameters 'commands=["findmnt --source soci"]' --query Command.CommandId --output text)"
      aws ssm wait command-executed --region "${REGION}" --command-id "${cmd}" --instance-id "${instance}" 2>/dev/null || true
      out="$(aws ssm get-command-invocation --region "${REGION}" --command-id "${cmd}" --instance-id "${instance}" \
        --query StandardOutputContent --output text)"
      if grep -q 'fuse' <<<"${out}"; then
        ok "cell ${id}: ${instance} has $(grep -c fuse <<<"${out}") SOCI FUSE mounts (lazy-loaded layers)"
      else
        fail "cell ${id}: ${instance} has no SOCI mounts"; rc=1
      fi
    done

    local frontends
    frontends="$(kc "${ctx}" get pods -n llm-inference \
      -l nvidia.com/dynamo-graph-deployment-name=stub-engine,nvidia.com/dynamo-component-type=frontend \
      --field-selector=status.phase=Running --no-headers | wc -l)"
    if [[ "${frontends}" -ge 1 ]]; then ok "cell ${id}: ${frontends} Dynamo frontend pod(s) running"; else fail "cell ${id}: no frontend"; rc=1; fi
  done
  return "${rc}"
}

################################################################################
dod4() {
  log "DoD 4: streaming chat completion returns OpenAI SSE chunks ending with data: [DONE]"
  local body
  body="$(curl --silent --show-error --no-buffer "${API}/chat/completions" \
    -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" -H "session-id: dod4-$(date +%s)" \
    -d "{\"model\":\"${MODEL}\",\"stream\":true,\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}]}")"
  local data last
  data="$(grep '^data: ' <<<"${body}" || true)"
  last="$(tail -n1 <<<"${data}")"
  if [[ "${last}" == "data: [DONE]" ]] && grep -v '^data: \[DONE\]' <<<"${data}" | head -1 | sed 's/^data: //' \
      | jq -e '.object == "chat.completion.chunk"' >/dev/null; then
    ok "$(($(wc -l <<<"${data}") - 1)) chat.completion.chunk events, then data: [DONE]"
  else
    fail "unexpected stream:"; echo "${body}" | head -20; return 1
  fi
}

served_cell() {
  curl --silent --output /dev/null --dump-header - "${API}/chat/completions" \
    -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" -H "session-id: $1" \
    -d "{\"model\":\"${MODEL}\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" \
    | tr -d '\r' | awk -F': ' 'tolower($1)=="x-served-cell"{print $2}'
}

dod5() {
  log "DoD 5: the same session-id is always served by the same cell"
  local sid cells
  sid="dod5-session-$(date +%s)"
  cells="$(for _ in $(seq 1 10); do served_cell "${sid}"; done | sort | uniq -c)"
  echo "${cells}"
  if [[ "$(wc -l <<<"${cells}")" -eq 1 && -n "$(tr -d ' ' <<<"${cells}")" ]]; then ok "10/10 requests on one cell"; else fail "session moved between cells"; return 1; fi
}

dod6() {
  log "DoD 6: different session-ids (same client) are spread across both cells"
  local counts
  counts="$(for i in $(seq 1 20); do served_cell "dod6-${i}-$(date +%s%N)"; done | sort | uniq -c)"
  echo "${counts}"
  if [[ "$(wc -l <<<"${counts}")" -ge "$(tf_deploy '.cells | length')" ]]; then ok "sessions spread over all cells"; else fail "not all cells served"; return 1; fi
}

dod7() {
  log "DoD 7: official OpenAI Python SDK (base_url, api_key, default_headers)"
  API_URL="${API}" ACCESS_TOKEN="${TOKEN}" python3 "${SCRIPTS_DIR}/verify_openai_sdk.py"
}

dod8() {
  log "DoD 8: POST without session-id returns 400 with an OpenAI-format error"
  local out code body
  out="$(curl --silent --write-out '\n%{http_code}' "${API}/chat/completions" \
    -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
    -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}")"
  code="$(tail -n1 <<<"${out}")"; body="$(sed '$d' <<<"${out}")"
  echo "${code} ${body}"
  if [[ "${code}" == "400" ]] && jq -e '.error.code == "missing_session_id" and .error.type == "invalid_request_error" and (.error.message | length > 0)' <<<"${body}" >/dev/null; then
    ok "400 missing_session_id"
  else
    fail "expected 400 missing_session_id"; return 1
  fi
}

dod9() {
  log "DoD 9: no/invalid token -> 401; port 80 not reachable"
  local rc=0 code
  code="$(curl --silent --output /dev/null --write-out '%{http_code}' "${API}/chat/completions" -H "session-id: s" -d '{}')"
  if [[ "${code}" == "401" ]]; then ok "no token: 401"; else fail "no token: ${code}"; rc=1; fi
  code="$(curl --silent --output /dev/null --write-out '%{http_code}' "${API}/chat/completions" \
    -H "Authorization: Bearer not-a-valid-token" -H "session-id: s" -d '{}')"
  if [[ "${code}" == "401" ]]; then ok "invalid token: 401"; else fail "invalid token: ${code}"; rc=1; fi
  if curl --silent --output /dev/null --connect-timeout 5 --max-time 8 "http://${HOST}/v1/models"; then
    fail "port 80 answered"; rc=1
  else
    ok "port 80 not reachable"
  fi
  return "${rc}"
}

################################################################################
TOKEN="$(access_token)"
[[ -n "${TOKEN}" && "${TOKEN}" != "null" ]] || die "could not get a Cognito access token"
MODEL="$(curl --silent --show-error --fail "${API}/models" -H "Authorization: Bearer ${TOKEN}" | jq -r '.data[0].id')"
log "API ${API}, model ${MODEL}"

check dod1
check dod2_3
check dod4
check dod5
check dod6
check dod7
check dod8
check dod9

echo
if ((failures == 0)); then ok "all Definition of Done checks passed"; else die "${failures} check group(s) failed"; fi

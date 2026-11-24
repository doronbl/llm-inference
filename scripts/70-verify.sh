#!/usr/bin/env bash
# Step 8: check every Definition of Done item (docs/architecture.md, sections
# 11 and 11a; ENGINE selects the engine, default vllm).
# Requires the tunnels from scripts/20-tunnels.sh (for DoD 2 and 3) and the
# openai package for DoD 7 (pip install openai==3.46.0). Set VERIFY_PYTHON to
# a Python that has it, for example a venv: VERIFY_PYTHON=~/.venvs/llm-verify/bin/python.
source "$(dirname "$0")/lib.sh"
require terraform aws kubectl jq curl python3

REGION="$(region)"
HOST="$(tf_deploy '.api_hostname')"
API="https://${HOST}/v1"
failures=0
check() { if "$@"; then :; else failures=$((failures + 1)); fi; }

################################################################################
dod1() {
  log "DoD 1: terraform created VPC, ACM, Cognito, ALB, Route 53, ECR, router cluster and the cells"
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
    'module.regional.module.cluster.module.eks.aws_eks_cluster.this[0]'; do
    if grep -qxF "${addr}" <<<"${state}"; then ok "${addr}"; else fail "${addr} missing"; ok_all=1; fi
  done
  local clusters want
  clusters="$(grep -c 'module.eks.aws_eks_cluster.this\[0\]$' <<<"${state}")"
  want=$(($(tf_deploy '.cells | length') + 1))
  if [[ "${clusters}" -eq "${want}" ]]; then ok "${clusters} EKS clusters (router + cells)"; else fail "${clusters} EKS clusters, want ${want}"; ok_all=1; fi
  local azs n_cells
  azs="$(tf_deploy '[.cells[].availability_zone] | unique | length')"
  n_cells="$(tf_deploy '.cells | length')"
  if [[ "${n_cells}" -ge 1 && "${azs}" -eq "${n_cells}" ]]; then
    ok "${n_cells} cell(s) in ${azs} AZ(s): $(tf_deploy '[.cells[] | "\(.cluster_name)@\(.availability_zone)"] | join(", ")')"
  else
    fail "need at least one cell, each in its own AZ"; ok_all=1
  fi
  return "${ok_all}"
}

################################################################################
# Runs one shell command on an instance through SSM and prints its stdout.
node_cmd() {
  local instance="$1" comment="$2" command="$3" cmd
  cmd="$(aws ssm send-command --region "${REGION}" --instance-ids "${instance}" \
    --document-name AWS-RunShellScript --comment "${comment}" \
    --parameters "$(jq -nc --arg c "${command}" '{commands: [$c]}')" --query Command.CommandId --output text)"
  aws ssm wait command-executed --region "${REGION}" --command-id "${cmd}" --instance-id "${instance}" 2>/dev/null || true
  aws ssm get-command-invocation --region "${REGION}" --command-id "${cmd}" --instance-id "${instance}" \
    --query StandardOutputContent --output text
}

dod2_3() {
  log "DoD 2: ${ENGINE} workers on Karpenter inference nodes (instance type, capacity type, EFA, GPUs, RAID0), behind the Dynamo frontend"
  log "DoD 3: SOCI on the inference nodes (parallel pull or lazy loading, per cell), checked through SSM"
  local rc=0
  for id in $(cell_ids); do
    local ctx expected_type efa_expected capacity_types soci_mode raid0 want_workers running nodes
    ctx="$(cell_cluster "${id}")"
    expected_type="$(cell_value "${id}" inference_instance_type)"
    efa_expected="$(cell_value "${id}" efa_interface_count)"
    capacity_types="$(tf_deploy ".cells[\"${id}\"].inference_capacity_types | join(\" \")")"
    soci_mode="$(cell_value "${id}" soci_pull_mode)"
    raid0="$(cell_value "${id}" instance_store_raid0)"

    want_workers="$(kc "${ctx}" -n llm-inference get dynamographdeployment "${ENGINE_DGD}" -o json \
      | jq -r '[.spec.components[] | select(.type == "worker") | .replicas] | add // 0')"
    running="$(kc "${ctx}" get pods -n llm-inference \
      -l "nvidia.com/dynamo-graph-deployment-name=${ENGINE_DGD},nvidia.com/dynamo-component-type=worker" \
      --field-selector=status.phase=Running -o json)"
    nodes="$(jq -r '[.items[].spec.nodeName] | unique | .[]' <<<"${running}")"
    if [[ "$(jq '.items | length' <<<"${running}")" -eq "${want_workers}" && "${want_workers}" -ge 1 ]]; then
      ok "cell ${id}: ${want_workers}/${want_workers} ${ENGINE} workers running"
    else
      fail "cell ${id}: $(jq '.items | length' <<<"${running}")/${want_workers} ${ENGINE} workers running"; rc=1
    fi
    [[ -n "${nodes}" ]] || { rc=1; continue; }

    for node in ${nodes}; do
      local info type nodepool capacity efa gpus gpu_count provider instance out
      info="$(kc "${ctx}" get node "${node}" -o json)"
      type="$(jq -r '.metadata.labels["node.kubernetes.io/instance-type"]' <<<"${info}")"
      nodepool="$(jq -r '.metadata.labels["karpenter.sh/nodepool"] // ""' <<<"${info}")"
      capacity="$(jq -r '.metadata.labels["karpenter.sh/capacity-type"] // ""' <<<"${info}")"
      efa="$(jq -r '.status.allocatable["vpc.amazonaws.com/efa"] // "0"' <<<"${info}")"
      gpus="$(jq -r '.status.allocatable["nvidia.com/gpu"] // "0"' <<<"${info}")"
      gpu_count="$(jq -r '.metadata.labels["karpenter.k8s.aws/instance-gpu-count"] // "0"' <<<"${info}")"
      if [[ "${nodepool}" == "inference" && "${type}" == "${expected_type}" && " ${capacity_types} " == *" ${capacity} "* \
            && "${efa}" -ge "${efa_expected}" && "${efa}" -ge 1 && "${gpus}" -eq "${gpu_count}" ]]; then
        ok "cell ${id}: ${node} (${type}, ${capacity}, nodepool=${nodepool}, vpc.amazonaws.com/efa=${efa}, nvidia.com/gpu=${gpus})"
      else
        fail "cell ${id}: ${node} type=${type} capacity=${capacity} nodepool=${nodepool} efa=${efa} gpu=${gpus}/${gpu_count} (want ${expected_type}, one of [${capacity_types}], inference, efa>=${efa_expected}, all GPUs allocatable)"; rc=1
      fi

      provider="$(jq -r '.spec.providerID' <<<"${info}")"
      instance="${provider##*/}"

      # Phase 1 DoD 3 is lazy loading of the mocker image.
      if [[ "${ENGINE}" == "stub" && "${soci_mode}" != "lazy" ]]; then
        fail "cell ${id}: ENGINE=stub expects soci_pull_mode = \"lazy\" (Phase 1 DoD 3), the cell has \"${soci_mode}\""; rc=1
      fi

      if [[ "${soci_mode}" == "lazy" ]]; then
        out="$(node_cmd "${instance}" "DoD3 SOCI mounts" 'findmnt --source soci')"
        if grep -q 'fuse' <<<"${out}"; then
          ok "cell ${id}: ${instance} has $(grep -c fuse <<<"${out}") SOCI FUSE mounts (lazy-loaded layers)"
        else
          fail "cell ${id}: ${instance} has no SOCI mounts"; rc=1
        fi
      else
        out="$(node_cmd "${instance}" "DoD3 SOCI parallel pull" \
          "awk '/^\\[/ { s = (\$0 == \"[pull_modes.parallel_pull_unpack]\") } s && /^enable *=/' /etc/soci-snapshotter-grpc/config.toml; ctr -n k8s.io snapshots --snapshotter soci ls | tail -n +2 | wc -l")"
        if grep -qxE 'enable *= *true' <<<"${out}" && [[ "$(tail -n1 <<<"${out}")" -ge 1 ]]; then
          ok "cell ${id}: ${instance} SOCI parallel pull enabled, $(tail -n1 <<<"${out}") snapshots in the soci snapshotter"
        else
          fail "cell ${id}: ${instance} SOCI parallel pull not active:"; echo "${out}"; rc=1
        fi
      fi

      if [[ "${raid0}" == "true" ]]; then
        out="$(node_cmd "${instance}" "DoD2 instance-store RAID0" \
          "grep -E '^md[0-9]+ : active raid0' /proc/mdstat; findmnt -n -o SOURCE --target /var/lib/kubelet")"
        if grep -q 'active raid0' <<<"${out}" && grep -q '^/dev/md' <<<"$(tail -n1 <<<"${out}")"; then
          ok "cell ${id}: ${instance} kubelet storage on instance-store RAID0 ($(tail -n1 <<<"${out}"))"
        else
          fail "cell ${id}: ${instance} kubelet storage is not on an instance-store RAID0:"; echo "${out}"; rc=1
        fi
      fi
    done

    local frontends
    frontends="$(kc "${ctx}" get pods -n llm-inference \
      -l "nvidia.com/dynamo-graph-deployment-name=${ENGINE_DGD},nvidia.com/dynamo-component-type=frontend" \
      --field-selector=status.phase=Running --no-headers | wc -l)"
    if [[ "${frontends}" -ge 1 ]]; then ok "cell ${id}: ${frontends} Dynamo frontend pod(s) running"; else fail "cell ${id}: no frontend"; rc=1; fi
  done
  return "${rc}"
}

################################################################################
# Request body for POST /v1/responses with a short output.
responses_body() {
  jq -nc --arg model "${MODEL}" --arg input "$1" --argjson stream "${2:-false}" \
    '{model: $model, input: $input, max_output_tokens: 16, stream: $stream}'
}

dod4() {
  log "DoD 4: streaming Responses API call returns OpenAI response events, a terminal event, then data: [DONE]"
  local body
  body="$(curl --silent --show-error --no-buffer "${API}/responses" \
    -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" -H "session-id: dod4-$(date +%s)" \
    -d "$(responses_body Hello true)")"
  local data types first final deltas
  data="$(grep '^data: ' <<<"${body}" || true)"
  types="$(grep -v '^data: \[DONE\]' <<<"${data}" | sed 's/^data: //' | jq -r '.type' 2>/dev/null || true)"
  first="$(head -n1 <<<"${types}")"
  final="$(tail -n1 <<<"${types}")"
  deltas="$(grep -c '^response.output_text.delta$' <<<"${types}" || true)"
  # The mocker and vLLM (short max_output_tokens) stop at the limit, so the terminal event is usually
  # response.incomplete; a model that finishes first sends response.completed.
  if [[ "$(tail -n1 <<<"${data}")" == "data: [DONE]" && "${first}" == "response.created" && "${deltas}" -ge 1 \
        && "${final}" =~ ^response\.(completed|incomplete)$ ]]; then
    ok "response.created, ${deltas} response.output_text.delta events, ${final}, then data: [DONE]"
  else
    fail "unexpected stream:"; echo "${body}" | head -20; return 1
  fi
}

dod4_only_responses() {
  log "DoD 4: only the Responses API and the model list are routed"
  local rc=0 path code
  for path in chat/completions completions; do
    code="$(curl --silent --output /dev/null --write-out '%{http_code}' "${API}/${path}" \
      -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" -H "session-id: dod4" -d '{}')"
    if [[ "${code}" == "404" ]]; then ok "POST /v1/${path}: 404"; else fail "POST /v1/${path}: ${code} (want 404)"; rc=1; fi
  done
  return "${rc}"
}

served_cell() {
  curl --silent --output /dev/null --dump-header - "${API}/responses" \
    -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" -H "session-id: $1" \
    -d "$(responses_body hi)" \
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
  log "DoD 6: different session-ids (same client) are spread across all cells"
  if [[ "$(tf_deploy '.cells | length')" -lt 2 ]]; then
    ok "single cell: nothing to spread (checked by DoD 5)"
    return 0
  fi
  local counts
  counts="$(for i in $(seq 1 20); do served_cell "dod6-${i}-$(date +%s%N)"; done | sort | uniq -c)"
  echo "${counts}"
  if [[ "$(wc -l <<<"${counts}")" -ge "$(tf_deploy '.cells | length')" ]]; then ok "sessions spread over all cells"; else fail "not all cells served"; return 1; fi
}

dod7() {
  log "DoD 7: official OpenAI Python SDK (base_url, api_key, default_headers)"
  API_URL="${API}" ACCESS_TOKEN="${TOKEN}" "${VERIFY_PYTHON:-python3}" "${SCRIPTS_DIR}/verify_openai_sdk.py"
}

dod8() {
  log "DoD 8: POST without session-id returns 400 with an OpenAI-format error"
  local out code body
  out="$(curl --silent --write-out '\n%{http_code}' "${API}/responses" \
    -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
    -d "$(responses_body hi)")"
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
  code="$(curl --silent --output /dev/null --write-out '%{http_code}' "${API}/responses" -H "session-id: s" -d '{}')"
  if [[ "${code}" == "401" ]]; then ok "no token: 401"; else fail "no token: ${code}"; rc=1; fi
  code="$(curl --silent --output /dev/null --write-out '%{http_code}' "${API}/responses" \
    -H "Authorization: Bearer not-a-valid-token" -H "session-id: s" -d '{}')"
  if [[ "${code}" == "401" ]]; then ok "invalid token: 401"; else fail "invalid token: ${code}"; rc=1; fi
  if curl --silent --output /dev/null --connect-timeout 5 --max-time 8 "http://${HOST}/v1/models"; then
    fail "port 80 answered"; rc=1
  else
    ok "port 80 not reachable"
  fi
  return "${rc}"
}

dod10() {
  log "DoD 10: requests are spread over all workers of a cell (Dynamo nvext.worker_id, non-streaming)"
  [[ "${ENGINE}" == "vllm" ]] || { ok "ENGINE=${ENGINE}: skipped"; return 0; }
  local rc=0 n_cells want n body workers distinct
  n_cells="$(tf_deploy '.cells | length')"
  for id in $(cell_ids); do
    want="$(kc "$(cell_cluster "${id}")" -n llm-inference get dynamographdeployment "${ENGINE_DGD}" -o json \
      | jq -r '[.spec.components[] | select(.type == "worker") | .replicas] | add // 0')"
    n=$((want * 3))
    workers=""
    local errors=0 headers worker
    headers="$(mktemp)"
    for i in $(seq 1 $((n * n_cells))); do
      local sid="dod10-${i}-$(date +%s%N)"
      : >"${headers}"
      # Single cell: every session lands here. Several cells: keep only this cell's sessions.
      if ! body="$(curl --silent --show-error --fail --dump-header "${headers}" "${API}/responses" \
        -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" -H "session-id: ${sid}" \
        -d "$(jq -nc --arg model "${MODEL}" '{model: $model, input: "hi", max_output_tokens: 4, nvext: {extra_fields: ["worker_id"]}}')")"; then
        errors=$((errors + 1)); continue
      fi
      [[ "$(tr -d '\r' <"${headers}" | awk -F': ' 'tolower($1)=="x-served-cell"{print $2}')" == "${id}" ]] || continue
      worker="$(jq -r '.nvext.worker_id | (.decode_worker_id // .prefill_worker_id) // empty' <<<"${body}" 2>/dev/null || true)"
      if [[ -n "${worker}" ]]; then workers+="${worker}"$'\n'; else errors=$((errors + 1)); fi
    done
    rm -f "${headers}"
    distinct="$(grep -v '^$' <<<"${workers}" | sort | uniq -c || true)"
    echo "${distinct}"
    if [[ "${errors}" -gt 0 ]]; then
      fail "cell ${id}: ${errors} request(s) failed or returned no nvext.worker_id"; rc=1
    elif [[ "$(grep -c . <<<"${distinct}")" -eq "${want}" ]]; then
      ok "cell ${id}: requests served by all ${want} workers"
    else
      fail "cell ${id}: $(grep -c . <<<"${distinct}") of ${want} workers served requests"; rc=1
    fi
  done
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
check dod4_only_responses
check dod5
check dod6
check dod7
check dod8
check dod9
check dod10

echo
if ((failures == 0)); then ok "all Definition of Done checks passed"; else die "${failures} check group(s) failed"; fi

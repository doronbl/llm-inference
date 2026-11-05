#!/usr/bin/env bash
# Step 2: open SSM port-forwarding tunnels to the private EKS API endpoints and
# write a kubeconfig with one context per cluster (context name = cluster name).
#
# Usage: OPERATOR_INSTANCE_ID=i-... scripts/20-tunnels.sh [start|stop|status]
#
# The operator instance is an EC2 instance inside the Region VPC with the SSM
# agent running (created manually; not part of this repository). Tunnels run
# in the background until "stop". kubectl authenticates with the operator
# host's own AWS credentials; the tunnel only carries the TLS connection.
source "$(dirname "$0")/lib.sh"

action="${1:-start}"

clusters() {
  router_cluster
  for id in $(cell_ids); do cell_cluster "${id}"; done
}

pid_file() { echo "${STATE_DIR}/tunnel-$1.pid"; }

stop_tunnels() {
  shopt -s nullglob
  for f in "${STATE_DIR}"/tunnel-*.pid; do
    local pid
    pid="$(cat "${f}")"
    # Each tunnel runs in its own process group (setsid): stop aws + plugin.
    kill -- "-${pid}" 2>/dev/null || true
    rm -f "${f}"
  done
  ok "tunnels stopped"
}

start_tunnel() {
  local cluster="$1" port="$2" endpoint host arn
  endpoint="$(aws eks describe-cluster --region "$(region)" --name "${cluster}" --query cluster.endpoint --output text)"
  arn="$(aws eks describe-cluster --region "$(region)" --name "${cluster}" --query cluster.arn --output text)"
  host="${endpoint#https://}"

  if [[ -f "$(pid_file "${cluster}")" ]] && kill -0 "$(cat "$(pid_file "${cluster}")")" 2>/dev/null; then
    ok "${cluster}: tunnel already running on 127.0.0.1:${port}"
  else
    setsid aws ssm start-session \
      --region "$(region)" \
      --target "${OPERATOR_INSTANCE_ID}" \
      --document-name AWS-StartPortForwardingSessionToRemoteHost \
      --parameters "host=${host},portNumber=443,localPortNumber=${port}" \
      >"${STATE_DIR}/tunnel-${cluster}.log" 2>&1 &
    echo $! >"$(pid_file "${cluster}")"
  fi

  aws eks update-kubeconfig --region "$(region)" --name "${cluster}" --alias "${cluster}" >/dev/null
  kubectl config set-cluster "${arn}" --server "https://127.0.0.1:${port}" --tls-server-name "${host}" >/dev/null

  for _ in $(seq 1 30); do
    if kubectl --context "${cluster}" version --request-timeout=5s >/dev/null 2>&1; then
      ok "${cluster}: context ready (127.0.0.1:${port} -> ${host})"
      return 0
    fi
    sleep 2
  done
  die "${cluster}: API not reachable through the tunnel; see ${STATE_DIR}/tunnel-${cluster}.log"
}

case "${action}" in
  start)
    require aws session-manager-plugin kubectl jq setsid
    : "${OPERATOR_INSTANCE_ID:?set OPERATOR_INSTANCE_ID to the operator EC2 instance ID}"
    log "Opening tunnels through ${OPERATOR_INSTANCE_ID}; kubeconfig: ${KUBECONFIG}"
    port="${TUNNEL_BASE_PORT}"
    for cluster in $(clusters); do
      start_tunnel "${cluster}" "${port}"
      port=$((port + 1))
    done
    echo
    echo "Use the same kubeconfig in your shell:"
    echo "  export KUBECONFIG=${KUBECONFIG}"
    ;;
  stop)
    stop_tunnels
    ;;
  status)
    shopt -s nullglob
    for f in "${STATE_DIR}"/tunnel-*.pid; do
      name="$(basename "${f}" .pid)"
      if kill -0 "$(cat "${f}")" 2>/dev/null; then ok "${name#tunnel-} running"; else fail "${name#tunnel-} stopped"; fi
    done
    ;;
  *)
    die "usage: $0 [start|stop|status]"
    ;;
esac

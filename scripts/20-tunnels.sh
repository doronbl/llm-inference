#!/usr/bin/env bash
# Step 2: open SSM port-forwarding tunnels to the private EKS API endpoints and
# write a kubeconfig with one context per cluster (context name = cluster name).
#
# Usage: OPERATOR_INSTANCE_ID=i-... scripts/20-tunnels.sh [start|keepalive|stop|status]
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

tunnel_running() {
  [[ -f "$(pid_file "$1")" ]] && kill -0 "$(cat "$(pid_file "$1")")" 2>/dev/null
}

# Starts the SSM port-forwarding session for one cluster in its own process
# group (setsid), unless it is already running.
start_session() {
  local cluster="$1" port="$2" host="$3"
  tunnel_running "${cluster}" && return 0
  setsid aws ssm start-session \
    --region "$(region)" \
    --target "${OPERATOR_INSTANCE_ID}" \
    --document-name AWS-StartPortForwardingSessionToRemoteHost \
    --parameters "host=${host},portNumber=443,localPortNumber=${port}" \
    >>"${STATE_DIR}/tunnel-${cluster}.log" 2>&1 &
  echo $! >"$(pid_file "${cluster}")"
}

endpoint_host() {
  local endpoint
  endpoint="$(aws eks describe-cluster --region "$(region)" --name "$1" --query cluster.endpoint --output text)"
  echo "${endpoint#https://}"
}

start_tunnel() {
  local cluster="$1" port="$2" host arn
  host="$(endpoint_host "${cluster}")"
  arn="$(aws eks describe-cluster --region "$(region)" --name "${cluster}" --query cluster.arn --output text)"

  if tunnel_running "${cluster}"; then
    ok "${cluster}: tunnel already running on 127.0.0.1:${port}"
  else
    start_session "${cluster}" "${port}" "${host}"
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
  keepalive)
    # Runs until killed. Session Manager closes a session after 20 minutes
    # without traffic (the default idle timeout), so this sends one small API
    # request through every tunnel each minute and restarts tunnels that have
    # exited. The kubeconfig is not rewritten, so it is safe to run next to
    # other kubectl commands. Run "start" first.
    require aws session-manager-plugin kubectl jq setsid
    : "${OPERATOR_INSTANCE_ID:?set OPERATOR_INSTANCE_ID to the operator EC2 instance ID}"
    declare -A hosts=()
    while :; do
      port="${TUNNEL_BASE_PORT}"
      for cluster in $(clusters); do
        if ! tunnel_running "${cluster}"; then
          [[ -n "${hosts[${cluster}]:-}" ]] || hosts[${cluster}]="$(endpoint_host "${cluster}")"
          fail "${cluster}: tunnel exited; restarting on 127.0.0.1:${port}"
          start_session "${cluster}" "${port}" "${hosts[${cluster}]}"
        else
          kubectl --context "${cluster}" version --request-timeout=10s >/dev/null 2>&1 || true
        fi
        port=$((port + 1))
      done
      sleep 60
    done
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
    die "usage: $0 [start|keepalive|stop|status]"
    ;;
esac

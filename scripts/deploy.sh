#!/usr/bin/env bash
# Runs the numbered deploy steps in order, unattended.
#
#   scripts/deploy.sh --to 10                              # step 0 and step 1 (terraform)
#   OPERATOR_INSTANCE_ID=i-... scripts/deploy.sh --from 20 # tunnels .. verify
#   OPERATOR_INSTANCE_ID=i-... scripts/deploy.sh           # all steps
#
# Steps: 00 10 20 30 40 41 50 60 70 (see README, "Deploy order"). Steps from
# 20 on need OPERATOR_INSTANCE_ID; the operator instance must be in the
# Region VPC, so on a first deploy run "--to 10", create it, then "--from 20".
#
# For each step:
#   - output goes to .state/<env>/logs/<UTC time>-<step>.log (timestamped
#     lines from lib.sh), and also to stdout
#   - one line per attempt is appended to .state/<env>/deploy.status
#   - a failed step is retried STEP_RETRIES more times (default 2; terraform
#     steps are not retried), after re-opening the tunnels
# While steps 20-70 run, "20-tunnels.sh keepalive" keeps the tunnels open.
# The runner stops at the first step that still fails after its retries.
#
# To keep it running after you log out:
#   setsid nohup scripts/deploy.sh --from 20 >/dev/null 2>&1 < /dev/null &
#   tail -f .state/region/deploy.status
source "$(dirname "$0")/lib.sh"

STEPS=(00 10 20 30 40 41 50 60 70)
from="00" to="70"
while (($#)); do
  case "$1" in
    --from) from="$2"; shift 2 ;;
    --to) to="$2"; shift 2 ;;
    *) die "usage: $0 [--from STEP] [--to STEP]   (steps: ${STEPS[*]})" ;;
  esac
done

LOG_DIR="${STATE_DIR}/logs"
STATUS_FILE="${STATE_DIR}/deploy.status"
mkdir -p "${LOG_DIR}"
retries="${STEP_RETRIES:-2}"

script_for() {
  local f
  f="$(ls "${SCRIPTS_DIR}/$1"-*.sh 2>/dev/null | head -1)"
  [[ -n "${f}" ]] || die "no script for step $1"
  echo "${f}"
}

args_for() {
  case "$1" in
    10) echo "-auto-approve" ;;
    20) echo "start" ;;
  esac
}

status() { echo "$(ts) $*" | tee -a "${STATUS_FILE}" >&2; }

keepalive_pid=""
start_keepalive() {
  [[ -n "${keepalive_pid}" ]] && kill -0 "${keepalive_pid}" 2>/dev/null && return 0
  "${SCRIPTS_DIR}/20-tunnels.sh" keepalive >>"${LOG_DIR}/tunnel-keepalive.log" 2>&1 &
  keepalive_pid=$!
}
stop_keepalive() { [[ -n "${keepalive_pid}" ]] && kill "${keepalive_pid}" 2>/dev/null || true; }
trap stop_keepalive EXIT

run_step() {
  local step="$1" script attempt max log rc
  script="$(script_for "${step}")"
  max=$((retries + 1))
  [[ "${step}" == "10" ]] && max=1
  for ((attempt = 1; attempt <= max; attempt++)); do
    log="${LOG_DIR}/$(date -u +%Y%m%dT%H%M%SZ)-$(basename "${script}" .sh).log"
    status "step ${step} $(basename "${script}") attempt ${attempt}/${max} started (log: ${log})"
    set +e
    # shellcheck disable=SC2046
    "${script}" $(args_for "${step}") 2>&1 | tee "${log}"
    rc=${PIPESTATUS[0]}
    set -e
    if ((rc == 0)); then
      status "step ${step} succeeded"
      return 0
    fi
    status "step ${step} failed with exit code ${rc}"
    if ((attempt < max)) && [[ "${step}" > "20" ]]; then
      "${SCRIPTS_DIR}/20-tunnels.sh" start >>"${LOG_DIR}/tunnel-keepalive.log" 2>&1 || true
      sleep 30
    fi
  done
  return 1
}

status "deploy started: steps ${from} to ${to}"
for step in "${STEPS[@]}"; do
  [[ "${step}" < "${from}" || "${step}" > "${to}" ]] && continue
  if [[ "${step}" > "10" ]]; then
    : "${OPERATOR_INSTANCE_ID:?set OPERATOR_INSTANCE_ID for steps 20 and later}"
  fi
  # Resuming after step 20: open the tunnels first.
  if [[ "${step}" > "20" && -z "${keepalive_pid}" ]]; then
    "${SCRIPTS_DIR}/20-tunnels.sh" start 2>&1 | tee -a "${LOG_DIR}/tunnel-keepalive.log" >&2 \
      || { status "deploy FAILED: tunnels did not open"; exit 1; }
    start_keepalive
  fi
  if ! run_step "${step}"; then
    status "deploy FAILED at step ${step}"
    exit 1
  fi
  [[ "${step}" == "20" ]] && start_keepalive
done
status "deploy finished: steps ${from} to ${to} succeeded"

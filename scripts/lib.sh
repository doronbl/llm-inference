#!/usr/bin/env bash
# Shared helpers for the deploy scripts: source it from a script. It enables
# strict mode (set -euo pipefail), so for an interactive shell use
# scripts/api-env.sh instead.
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPTS_DIR}/.." && pwd)"
ENV_DIR="${ENV_DIR:-${REPO_ROOT}/infra/envs/region}"
STATE_DIR="${STATE_DIR:-${REPO_ROOT}/.state/$(basename "${ENV_DIR}")}"
export KUBECONFIG="${KUBECONFIG_FILE:-${STATE_DIR}/kubeconfig}"

# shellcheck source=versions.env
source "${SCRIPTS_DIR}/versions.env"

mkdir -p "${STATE_DIR}"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '\n\033[1;34m==> [%s] %s\033[0m\n' "$(ts)" "$*" >&2; }
ok() { printf '\033[1;32m  ok\033[0m  [%s] %s\n' "$(ts)" "$*" >&2; }
fail() { printf '\033[1;31mFAIL\033[0m  [%s] %s\n' "$(ts)" "$*" >&2; }
die() { fail "$*"; exit 1; }

require() {
  local missing=()
  for cmd in "$@"; do command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}"); done
  ((${#missing[@]} == 0)) || die "missing tools: ${missing[*]}"
}

# Terraform "deploy" output, cached in a file (refreshed when the state changes)
# so that calls from subshells do not rerun terraform.
DEPLOY_JSON_FILE="${STATE_DIR}/deploy.json"
tf_deploy() {
  if [[ ! -s "${DEPLOY_JSON_FILE}" || "${ENV_DIR}/terraform.tfstate" -nt "${DEPLOY_JSON_FILE}" ]]; then
    terraform -chdir="${ENV_DIR}" output -json deploy >"${DEPLOY_JSON_FILE}.tmp" \
      || die "terraform output failed; run scripts/10-terraform-apply.sh first"
    mv "${DEPLOY_JSON_FILE}.tmp" "${DEPLOY_JSON_FILE}"
  fi
  jq -r "$1" "${DEPLOY_JSON_FILE}"
}

region() { tf_deploy '.region'; }
router_cluster() { tf_deploy '.router.cluster_name'; }
cell_ids() { tf_deploy '.cells | keys[]'; }
cell_value() { tf_deploy ".cells[\"$1\"].$2"; }
cell_cluster() { cell_value "$1" cluster_name; }

# kubectl/helm against a cluster; the kube context is named after the cluster.
kc() { local ctx="$1"; shift; kubectl --context "${ctx}" "$@"; }
hc() { local ctx="$1"; shift; helm --kube-context "${ctx}" "$@"; }

# Render a template with envsubst, substituting only the listed variables.
render() {
  local template="$1"; shift
  local vars=""
  for v in "$@"; do vars+="\${${v}} "; done
  envsubst "${vars}" <"${template}"
}

# Fetch a Cognito access token (client-credentials grant).
access_token() {
  local secret
  secret="$(terraform -chdir="${ENV_DIR}" output -raw cognito_client_secret)"
  curl --silent --show-error --fail \
    --user "$(tf_deploy '.cognito.client_id'):${secret}" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "scope=$(tf_deploy '.cognito.required_scope')" \
    "$(tf_deploy '.cognito.token_endpoint')" | jq -r '.access_token'
}

image_env() {
  [[ -f "${STATE_DIR}/images.env" ]] || die "no image references; run scripts/30-images.sh first"
  # shellcheck disable=SC1091
  source "${STATE_DIR}/images.env"
}

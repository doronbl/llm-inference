#!/usr/bin/env bash
# Step 3: push the platform-owned images to ECR.
#
#   router          built from router/Dockerfile, pushed with Docker
#                   -> <ecr>/router:<git-sha>
#   dynamo-planner  mirrored from nvcr.io (pinned digest) and converted to a
#                   SOCI-enabled image (SOCI index manifest v2) for lazy loading
#                   -> <ecr>/dynamo-planner:1.6.1-soci
#
# The router image is small, so it gets no SOCI index. The SOCI conversion runs
# on this host with the soci CLI against containerd (nerdctl + sudo).
# Image references are written to .state/<env>/images.env.
source "$(dirname "$0")/lib.sh"
require aws docker nerdctl soci jq git

REGION="$(region)"
ROUTER_REPO="$(tf_deploy '.ecr_repository_urls.router')"
PLANNER_REPO="$(tf_deploy '.ecr_repository_urls["dynamo-planner"]')"
REGISTRY="${ROUTER_REPO%%/*}"
PLATFORM="linux/amd64"

tag_exists() {
  local repo="$1" tag="$2"
  aws ecr describe-images --region "${REGION}" --repository-name "${repo#*/}" \
    --image-ids "imageTag=${tag}" >/dev/null 2>&1
}

# Fails unless the pushed image index references a SOCI index manifest.
assert_soci_index() {
  local repo="$1" tag="$2" manifest
  manifest="$(aws ecr batch-get-image --region "${REGION}" --repository-name "${repo#*/}" \
    --image-ids "imageTag=${tag}" \
    --accepted-media-types application/vnd.oci.image.index.v1+json \
    --query 'images[0].imageManifest' --output text)"
  jq -e '[.manifests[]? | (.artifactType // "") , (.annotations // {} | tostring)] | any(test("soci"))' \
    <<<"${manifest}" >/dev/null || die "${repo}:${tag} has no SOCI index"
  ok "${repo}:${tag} carries a SOCI index"
}

log "Logging in to ECR (${REGISTRY})"
aws ecr get-login-password --region "${REGION}" | docker login --username AWS --password-stdin "${REGISTRY}" >/dev/null
aws ecr get-login-password --region "${REGION}" | sudo nerdctl login --username AWS --password-stdin "${REGISTRY}" >/dev/null
ok "logged in"

################################################################################
# Router (Docker only)
################################################################################
ROUTER_TAG="${ROUTER_TAG:-$(git -C "${REPO_ROOT}" rev-parse --short=12 HEAD)}"
if [[ -n "$(git -C "${REPO_ROOT}" status --porcelain -- router)" ]]; then
  ROUTER_TAG="${ROUTER_TAG}-dirty-$(date +%s)"
fi

log "Router image ${ROUTER_REPO}:${ROUTER_TAG}"
if tag_exists "${ROUTER_REPO}" "${ROUTER_TAG}"; then
  ok "already pushed"
else
  docker build --platform "${PLATFORM}" -t "${ROUTER_REPO}:${ROUTER_TAG}" "${REPO_ROOT}/router"
  docker push "${ROUTER_REPO}:${ROUTER_TAG}"
fi

################################################################################
# Dynamo planner mirror (frontend + mocker), SOCI-enabled
################################################################################
log "Dynamo image ${PLANNER_REPO}:${DYNAMO_PLANNER_MIRROR_TAG}"
if tag_exists "${PLANNER_REPO}" "${DYNAMO_PLANNER_MIRROR_TAG}"; then
  ok "already pushed"
else
  sudo nerdctl pull --quiet --platform "${PLATFORM}" "${DYNAMO_PLANNER_SOURCE}"
  sudo soci convert --platform "${PLATFORM}" "${DYNAMO_PLANNER_SOURCE}" "${PLANNER_REPO}:${DYNAMO_PLANNER_MIRROR_TAG}"
  sudo nerdctl push --platform "${PLATFORM}" "${PLANNER_REPO}:${DYNAMO_PLANNER_MIRROR_TAG}"
fi
assert_soci_index "${PLANNER_REPO}" "${DYNAMO_PLANNER_MIRROR_TAG}"

cat >"${STATE_DIR}/images.env" <<EOF
ROUTER_IMAGE="${ROUTER_REPO}:${ROUTER_TAG}"
DYNAMO_IMAGE="${PLANNER_REPO}:${DYNAMO_PLANNER_MIRROR_TAG}"
EOF
ok "wrote ${STATE_DIR}/images.env"
cat "${STATE_DIR}/images.env"

#!/usr/bin/env bash
# Step 0: check the operator host has every tool the deploy needs.
source "$(dirname "$0")/lib.sh"

log "Checking tools"
require terraform aws session-manager-plugin kubectl helm jq envsubst curl git docker nerdctl soci python3 setsid

terraform version -json | jq -e '.terraform_version | startswith("1.17.")' >/dev/null \
  || die "Terraform 1.17.x required (infra/envs/region/versions.tf)"
ok "terraform $(terraform version -json | jq -r .terraform_version)"
ok "helm $(helm version --short)"
ok "kubectl $(kubectl version --client -o json | jq -r .clientVersion.gitVersion)"
ok "soci $(soci --version 2>/dev/null | head -1)"

log "Checking container tooling (SOCI conversion runs under sudo against containerd)"
sudo -n true 2>/dev/null || echo "  note: sudo will prompt for a password in scripts/30-images.sh"
sudo nerdctl version >/dev/null || die "nerdctl cannot reach containerd"
ok "containerd reachable through nerdctl"
docker info >/dev/null || die "docker daemon not reachable"
ok "docker daemon reachable"

log "Checking AWS credentials"
aws sts get-caller-identity --query Arn --output text
ok "AWS credentials work"

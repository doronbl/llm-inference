#!/usr/bin/env bash
# Step 1: create the Region: VPC, edge (ACM, Cognito, ALB, Route 53), ECR
# repositories, regional router cluster and the cells.
source "$(dirname "$0")/lib.sh"
require terraform

[[ -f "${ENV_DIR}/terraform.tfvars" ]] \
  || die "create ${ENV_DIR}/terraform.tfvars from terraform.tfvars.example first"

log "terraform init (${ENV_DIR})"
terraform -chdir="${ENV_DIR}" init -input=false

log "terraform apply"
terraform -chdir="${ENV_DIR}" apply -input=false "$@"

log "Created"
terraform -chdir="${ENV_DIR}" output -json deploy \
  | jq '{region, api_url, router: .router.cluster_name, cells: (.cells | map_values({cluster_name, availability_zone, inference_instance_type}))}'

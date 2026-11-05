# scripts/ read these with `terraform output -json deploy`.
output "deploy" {
  description = "Non-secret values consumed by the deploy scripts."
  value = {
    region       = var.region
    vpc_id       = module.network.vpc_id
    vpc_cidr     = module.network.vpc_cidr
    api_hostname = var.api_hostname
    api_url      = module.edge.api_url

    cognito = {
      token_endpoint = module.edge.cognito_token_endpoint
      client_id      = module.edge.cognito_client_id
      issuer         = module.edge.cognito_issuer
      jwks_url       = module.edge.cognito_jwks_url
      required_scope = module.edge.cognito_required_scope
    }

    ecr_repository_urls = module.regional.ecr_repository_urls

    router = {
      cluster_name     = module.regional.cluster_name
      cluster_endpoint = module.regional.cluster_endpoint
      target_group_arn = module.edge.router_target_group_arn
      port             = local.router_port
    }

    cells = {
      for id, c in module.cell : id => {
        cell_id                      = c.cell_id
        availability_zone            = c.availability_zone
        cluster_name                 = c.cluster_name
        cluster_endpoint             = c.cluster_endpoint
        subnet_id                    = c.subnet_id
        inference_instance_type      = c.inference_instance_type
        efa_interface_count          = c.efa_interface_count
        karpenter_interruption_queue = c.karpenter_interruption_queue
        karpenter_manifests          = c.karpenter_manifests
      }
    }
  }
}

output "cognito_client_secret" {
  description = "Cognito app client secret (read with: terraform output -raw cognito_client_secret)."
  value       = module.edge.cognito_client_secret
  sensitive   = true
}

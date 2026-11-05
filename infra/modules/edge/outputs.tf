output "alb_dns_name" {
  description = "DNS name of the public ALB."
  value       = aws_lb.this.dns_name
}

output "alb_security_group_id" {
  description = "Security group of the public ALB (source of traffic to router pods)."
  value       = aws_security_group.alb.id
}

output "router_target_group_arn" {
  description = "ARN of the IP target group that router pods are bound to."
  value       = aws_lb_target_group.router.arn
}

output "api_url" {
  description = "Base URL of the OpenAI-compatible API."
  value       = "https://${var.api_hostname}/v1"
}

output "cognito_user_pool_id" {
  description = "Cognito user pool ID."
  value       = aws_cognito_user_pool.this.id
}

output "cognito_issuer" {
  description = "Expected iss claim of access tokens."
  value       = local.issuer
}

output "cognito_jwks_url" {
  description = "JWKS URL of the user pool."
  value       = local.jwks_url
}

output "cognito_token_endpoint" {
  description = "OAuth 2.0 token endpoint (client-credentials grant)."
  value       = local.token_endpoint
}

output "cognito_required_scope" {
  description = "Scope every access token must carry."
  value       = local.required_scope
}

output "cognito_client_id" {
  description = "App client ID."
  value       = aws_cognito_user_pool_client.m2m.id
}

output "cognito_client_secret" {
  description = "App client secret."
  value       = aws_cognito_user_pool_client.m2m.client_secret
  sensitive   = true
}

output "cluster_name" {
  description = "Name of the regional router cluster."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Private Kubernetes API endpoint."
  value       = module.eks.cluster_endpoint
}

output "node_security_group_id" {
  description = "Security group of the router cluster nodes and pods."
  value       = module.eks.node_security_group_id
}

output "lbc_role_arn" {
  description = "IRSA role of the AWS Load Balancer Controller."
  value       = module.lbc_irsa.arn
}

output "ecr_repository_urls" {
  description = "Map of short repository name to ECR repository URL."
  value       = { for k, r in aws_ecr_repository.this : k => r.repository_url }
}

output "cluster_name" {
  description = "Name of the regional router cluster."
  value       = module.cluster.cluster_name
}

output "cluster_endpoint" {
  description = "Private Kubernetes API endpoint."
  value       = module.cluster.cluster_endpoint
}

output "node_security_group_id" {
  description = "Security group of the router cluster nodes and pods."
  value       = module.cluster.node_security_group_id
}

output "ecr_repository_urls" {
  description = "Map of short repository name to ECR repository URL."
  value       = { for k, r in aws_ecr_repository.this : k => r.repository_url }
}

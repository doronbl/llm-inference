output "vpc_id" {
  description = "VPC ID."
  value       = module.vpc.vpc_id
}

output "vpc_cidr" {
  description = "VPC IPv4 CIDR block."
  value       = module.vpc.vpc_cidr_block
}

output "private_subnet_ids" {
  description = "Private subnet IDs, in the same order as var.azs."
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "Public subnet IDs, in the same order as var.azs."
  value       = module.vpc.public_subnets
}

output "private_subnet_ids_by_az" {
  description = "Map of Availability Zone to private subnet ID."
  value       = zipmap(var.azs, module.vpc.private_subnets)
}

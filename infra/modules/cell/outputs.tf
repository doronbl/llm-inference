output "cell_id" {
  description = "Cell identifier."
  value       = var.cell_id
}

output "availability_zone" {
  description = "Availability Zone of the cell."
  value       = var.availability_zone
}

output "cluster_name" {
  description = "Name of the cell EKS cluster."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Private Kubernetes API endpoint."
  value       = module.eks.cluster_endpoint
}

output "subnet_id" {
  description = "Private subnet of the cell (nodes and internal NLB)."
  value       = var.cell_subnet_id
}

output "node_security_group_id" {
  description = "Node security group (system and inference nodes)."
  value       = module.eks.node_security_group_id
}

output "efa_security_group_id" {
  description = "Self-referencing EFA security group for inference nodes."
  value       = aws_security_group.efa.id
}

output "placement_group_name" {
  description = "Cluster placement group of the inference nodes."
  value       = aws_placement_group.inference.name
}

output "inference_instance_type" {
  description = "Instance type of the inference NodePool."
  value       = var.inference_instance_type
}

output "efa_enabled" {
  description = "Whether inference nodes get EFA-only interfaces."
  value       = var.efa_enabled
}

output "efa_interface_count" {
  description = "Number of EFA-only interfaces per inference node."
  value       = local.efa_interface_count
}

output "inference_network_interfaces" {
  description = "EC2NodeClass spec.networkInterfaces for the inference NodePool (empty when EFA is disabled)."
  value       = local.inference_network_interfaces
}

output "karpenter_controller_role_arn" {
  description = "IRSA role of the Karpenter controller."
  value       = module.karpenter.iam_role_arn
}

output "karpenter_node_role_name" {
  description = "IAM role of Karpenter-launched nodes (EC2NodeClass spec.role)."
  value       = module.karpenter.node_iam_role_name
}

output "karpenter_interruption_queue" {
  description = "SQS interruption queue name for Karpenter."
  value       = module.karpenter.queue_name
}

output "lbc_role_arn" {
  description = "IRSA role of the AWS Load Balancer Controller."
  value       = module.lbc_irsa.arn
}

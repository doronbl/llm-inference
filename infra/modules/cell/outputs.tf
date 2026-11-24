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
  value       = module.cluster.cluster_name
}

output "cluster_endpoint" {
  description = "Private Kubernetes API endpoint."
  value       = module.cluster.cluster_endpoint
}

output "subnet_id" {
  description = "Private subnet of the cell (nodes and internal NLB)."
  value       = var.cell_subnet_id
}

output "inference_instance_type" {
  description = "Instance type of the inference NodePool."
  value       = var.inference_instance_type
}

output "inference_capacity_types" {
  description = "Karpenter capacity types of the inference NodePool."
  value       = var.inference_capacity_types
}

output "soci_pull_mode" {
  description = "SOCI snapshotter mode on inference nodes (parallel or lazy)."
  value       = var.soci_pull_mode
}

output "instance_store_raid0" {
  description = "Whether inference nodes combine their instance-store NVMe volumes into one RAID0 array (instance types with local storage)."
  value       = local.instance_store_raid0
}

output "efa_interface_count" {
  description = "Number of EFA-only interfaces per inference node."
  value       = local.efa_interface_count
}

output "inference_network_interfaces" {
  description = "EC2NodeClass spec.networkInterfaces of the inference NodePool (empty when EFA is disabled)."
  value       = local.inference_network_interfaces
}

output "karpenter_interruption_queue" {
  description = "SQS interruption queue name for Karpenter."
  value       = module.karpenter.queue_name
}

output "karpenter_manifests" {
  description = "Inference EC2NodeClass and NodePool (multi-document YAML) for kubectl apply."
  value       = local.karpenter_manifests
}

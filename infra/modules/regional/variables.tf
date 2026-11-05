variable "cluster_name" {
  description = "Name of the regional router EKS cluster."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes minor version of the cluster."
  type        = string
}

variable "addon_versions" {
  description = "Pinned EKS add-on versions (keys: eks-pod-identity-agent, vpc-cni, kube-proxy, coredns)."
  type        = map(string)
}

variable "ami_release_version" {
  description = "Pinned EKS-optimized AL2023 AMI release version for the system node group."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR (allowed to reach the private Kubernetes API)."
  type        = string
}

variable "node_subnet_ids" {
  description = "Private subnets for the system node group."
  type        = list(string)
}

variable "control_plane_subnet_ids" {
  description = "Private subnets (at least two AZs) for the EKS control plane ENIs."
  type        = list(string)
}

variable "system_instance_types" {
  description = "Instance types of the system managed node group."
  type        = list(string)
}

variable "system_node_min_size" {
  description = "Minimum size of the system node group."
  type        = number
  default     = 2
}

variable "system_node_desired_size" {
  description = "Desired size of the system node group."
  type        = number
  default     = 2
}

variable "system_node_max_size" {
  description = "Maximum size of the system node group."
  type        = number
  default     = 4
}

variable "system_node_volume_size_gib" {
  description = "Root volume size of system nodes, in GiB."
  type        = number
  default     = 100
}

variable "node_cloudinit_parts" {
  description = "cloud-init parts placed before the EKS-generated NodeConfig of the system node group."
  type = list(object({
    content      = string
    content_type = optional(string)
    filename     = optional(string)
    merge_type   = optional(string)
  }))
  default = []
}

variable "admin_principal_arns" {
  description = "IAM principals (operators) granted cluster-admin through EKS access entries."
  type        = list(string)
  default     = []
}

variable "alb_security_group_id" {
  description = "Security group of the public ALB, allowed to reach router pods."
  type        = string
}

variable "router_port" {
  description = "Container port of the router pods."
  type        = number
  default     = 8080
}

variable "ecr_namespace" {
  description = "Namespace prefix of the ECR repositories."
  type        = string
}

variable "ecr_repository_names" {
  description = "ECR repositories owned by the platform."
  type        = list(string)
  default     = ["router", "dynamo-planner"]
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}

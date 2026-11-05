variable "cluster_name" {
  description = "Name of the EKS cluster."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes minor version of the cluster."
  type        = string
}

variable "addon_versions" {
  description = "Pinned EKS add-on versions (keys: eks-pod-identity-agent, vpc-cni, kube-proxy, coredns)."
  type        = map(string)

  validation {
    condition     = alltrue([for k in ["eks-pod-identity-agent", "vpc-cni", "kube-proxy", "coredns"] : contains(keys(var.addon_versions), k)])
    error_message = "addon_versions must pin eks-pod-identity-agent, vpc-cni, kube-proxy and coredns."
  }
}

variable "ami_release_version" {
  description = "Pinned EKS-optimized AL2023 AMI release version of the system node group."
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
  description = "Private subnets of the system node group."
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

variable "system_node_volume_throughput" {
  description = "gp3 throughput of the system node root volume, in MiB/s."
  type        = number
  default     = 250
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

variable "node_security_group_additional_rules" {
  description = "Extra rules for the node security group (see terraform-aws-modules/eks)."
  type = map(object({
    protocol                      = optional(string, "tcp")
    from_port                     = number
    to_port                       = number
    type                          = optional(string, "ingress")
    description                   = optional(string)
    cidr_blocks                   = optional(list(string))
    ipv6_cidr_blocks              = optional(list(string))
    prefix_list_ids               = optional(list(string))
    self                          = optional(bool)
    source_cluster_security_group = optional(bool, false)
    source_security_group_id      = optional(string)
  }))
  default = {}
}

variable "node_security_group_tags" {
  description = "Extra tags for the node security group."
  type        = map(string)
  default     = {}
}

variable "admin_principal_arns" {
  description = "IAM principals (operators) granted cluster-admin through EKS access entries."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}

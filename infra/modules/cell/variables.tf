################################################################################
# Cell identity (the inputs every cell differs by)
################################################################################

variable "region" {
  description = "AWS Region of the cell."
  type        = string
}

variable "availability_zone" {
  description = "Availability Zone the cell is pinned to (nodes, NLB, placement group)."
  type        = string
}

variable "cell_id" {
  description = "Short cell identifier, unique within the Region (for example \"a\")."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{1,8}$", var.cell_id))
    error_message = "cell_id must be 1-8 lowercase letters or digits."
  }
}

variable "inference_instance_type" {
  description = "Instance type of the Karpenter inference NodePool."
  type        = string
  default     = "c8i.48xlarge"
}

variable "efa_enabled" {
  description = "Attach EFA-only interfaces (up to the instance maximum) to inference nodes."
  type        = bool
  default     = true
}

variable "inference_cpu_limit" {
  description = "Upper bound of inference vCPUs per cell (NodePool limit); 960 = 5 x c8i.48xlarge."
  type        = number
  default     = 960
}

################################################################################
# Shared settings (identical for every cell in a Region)
################################################################################

variable "name_prefix" {
  description = "Prefix of the cluster name; the cluster is named <name_prefix>-<cell_id>."
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
  description = "Pinned EKS-optimized AL2023 AMI release (for example 1.37.1-20261031), used by the system node group and, as the Karpenter alias al2023@v<date>, by inference nodes."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+-[0-9]{8}$", var.ami_release_version))
    error_message = "ami_release_version must look like 1.37.1-20261031."
  }
}

variable "platform_dir" {
  description = "Path of the repository's platform/ directory (Karpenter templates, SOCI node config)."
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

variable "cell_subnet_id" {
  description = "Private subnet in availability_zone for system and inference nodes."
  type        = string
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
  description = "Root volume size of system nodes, in GiB (holds the Dynamo frontend image)."
  type        = number
  default     = 200
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

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}

################################################################################
# Environment-specific values (supply them in terraform.tfvars)
################################################################################

variable "region" {
  description = "AWS Region of this environment."
  type        = string
}

variable "hosted_zone_name" {
  description = "Name of the existing public Route 53 hosted zone (for example example.com)."
  type        = string
}

variable "api_hostname" {
  description = "API hostname inside hosted_zone_name (for example api.example.com)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.api_hostname))
    error_message = "api_hostname must be a lowercase fully qualified domain name."
  }
}

variable "vpc_cidr" {
  description = "IPv4 CIDR of the Region VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "cells" {
  description = "Cells of this Region, keyed by cell_id. Each cell is pinned to its own Availability Zone."
  type = map(object({
    availability_zone       = string
    inference_instance_type = optional(string, "c8i.48xlarge")
    efa_enabled             = optional(bool, true)
  }))

  validation {
    condition     = length(var.cells) >= 1
    error_message = "Define at least one cell."
  }

  validation {
    condition     = length(distinct([for c in values(var.cells) : c.availability_zone])) == length(var.cells)
    error_message = "Every cell must be in a different Availability Zone."
  }
}

variable "extra_azs" {
  description = "Additional AZs for subnets when the cells cover fewer than two AZs (EKS control plane and ALB need two)."
  type        = list(string)
  default     = []
}

variable "regional_system_instance_types" {
  description = "Instance types of the regional router cluster system node group."
  type        = list(string)
  default     = ["c8i.xlarge"]
}

variable "cell_system_instance_types" {
  description = "Instance types of the cell system node groups."
  type        = list(string)
  default     = ["c8i.2xlarge"]
}

variable "operator_principal_arns" {
  description = "Extra IAM role/user ARNs that get cluster-admin on every cluster. The Terraform caller is added automatically; do not repeat it here."
  type        = list(string)
  default     = []
}

################################################################################
# Shared defaults (normally left unchanged)
################################################################################

variable "name" {
  description = "Project name prefix for resources."
  type        = string
  default     = "llm"
}

variable "kubernetes_version" {
  description = "Kubernetes minor version of all clusters."
  type        = string
  default     = "1.37"
}

variable "ami_release_version" {
  description = "EKS-optimized AL2023 AMI release of all nodes: system node groups use it directly, Karpenter inference nodes as the alias al2023@v<date>."
  type        = string
  default     = "1.37.1-20261031"
}

variable "addon_versions" {
  description = "Pinned EKS add-on versions."
  type        = map(string)
  default = {
    "eks-pod-identity-agent" = "v1.4.1-eksbuild.3"
    "vpc-cni"                = "v1.22.4-eksbuild.10"
    "kube-proxy"             = "v1.37.0-eksbuild.32"
    "coredns"                = "v1.14.7-eksbuild.22"
  }
}

variable "tags" {
  description = "Extra tags applied to every resource."
  type        = map(string)
  default     = {}
}

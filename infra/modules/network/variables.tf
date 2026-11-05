variable "name" {
  description = "Name prefix for the VPC and its resources."
  type        = string
}

variable "vpc_cidr" {
  description = "IPv4 CIDR block of the VPC (a /16 is expected)."
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && tonumber(split("/", var.vpc_cidr)[1]) <= 16
    error_message = "vpc_cidr must be a valid IPv4 CIDR with a prefix length of /16 or shorter."
  }
}

variable "azs" {
  description = "Availability Zones that get a private and a public subnet. Must include every cell AZ and at least two AZs in total."
  type        = list(string)

  validation {
    condition     = length(var.azs) >= 2 && length(var.azs) <= 3 && length(distinct(var.azs)) == length(var.azs)
    error_message = "azs must contain 2 or 3 distinct Availability Zones (a /16 holds three /18 private subnets plus the public /24s)."
  }
}

variable "private_subnet_prefix_length" {
  description = "Prefix length of each private subnet (nodes and pods)."
  type        = number
  default     = 18
}

variable "public_subnet_prefix_length" {
  description = "Prefix length of each public subnet (ALB and NAT gateways only)."
  type        = number
  default     = 24
}

variable "interface_endpoint_services" {
  description = "Interface VPC endpoint service names (the S3 gateway endpoint is always created)."
  type        = list(string)
  default     = ["ecr.api", "ecr.dkr", "sts", "ec2", "ssm", "ssmmessages", "ec2messages", "eks"]
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}

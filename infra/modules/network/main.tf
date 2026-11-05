# One VPC per Region, shared by the regional router cluster and every cell.
#
# Address plan (for a /16 VPC CIDR):
#   private subnets: one /18 per AZ, allocated from the bottom of the range
#   public subnets:  one /24 per AZ, allocated from the top of the range
# The two ranges never overlap as long as fewer than four AZs are used
# (enforced by the validation on var.azs).

locals {
  vpc_prefix_len = tonumber(split("/", var.vpc_cidr)[1])

  private_newbits = var.private_subnet_prefix_length - local.vpc_prefix_len
  public_newbits  = var.public_subnet_prefix_length - local.vpc_prefix_len

  private_subnets = [for i, _ in var.azs : cidrsubnet(var.vpc_cidr, local.private_newbits, i)]
  public_subnets = [
    for i, _ in var.azs : cidrsubnet(var.vpc_cidr, local.public_newbits, pow(2, local.public_newbits) - 1 - i)
  ]

  endpoint_azs = length(var.endpoint_azs) > 0 ? var.endpoint_azs : var.azs
  endpoint_subnet_ids = [
    for az, id in zipmap(var.azs, module.vpc.private_subnets) : id if contains(local.endpoint_azs, az)
  ]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.3"

  name = var.name
  cidr = var.vpc_cidr
  azs  = var.azs

  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets

  enable_nat_gateway     = true
  single_nat_gateway     = false
  one_nat_gateway_per_az = true

  enable_dns_hostnames = true
  enable_dns_support   = true

  map_public_ip_on_launch = false

  # Subnet role tags used by the AWS Load Balancer Controller for subnet discovery.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
    "subnet-tier"            = "public"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
    "subnet-tier"                     = "private"
  }

  tags = var.tags
}

resource "aws_security_group" "vpc_endpoints" {
  name_prefix = "${var.name}-vpce-"
  description = "Interface VPC endpoints: HTTPS from inside the VPC"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "HTTPS from the VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Responses"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = merge(var.tags, { Name = "${var.name}-vpce" })

  lifecycle {
    create_before_destroy = true
  }
}

module "vpc_endpoints" {
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "6.7.3"

  vpc_id             = module.vpc.vpc_id
  security_group_ids = [aws_security_group.vpc_endpoints.id]

  endpoints = merge(
    {
      s3 = {
        service         = "s3"
        service_type    = "Gateway"
        route_table_ids = module.vpc.private_route_table_ids
        tags            = { Name = "${var.name}-s3" }
      }
    },
    {
      for svc in var.interface_endpoint_services : replace(svc, ".", "_") => {
        service             = svc
        private_dns_enabled = true
        subnet_ids          = local.endpoint_subnet_ids
        tags                = { Name = "${var.name}-${svc}" }
      }
    }
  )

  tags = var.tags
}

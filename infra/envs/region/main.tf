# One environment per Region. To add a Region, copy this directory and supply
# a new terraform.tfvars; the Route 53 record created by the edge module joins
# the existing latency-based record set for the same hostname.

provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}

locals {
  name_prefix = "${var.name}-${var.region}"

  tags = merge(var.tags, {
    Project   = "llm-inference"
    Region    = var.region
    ManagedBy = "terraform"
  })

  cell_azs = sort([for c in values(var.cells) : c.availability_zone])
  azs      = distinct(concat(local.cell_azs, var.extra_azs))

  # cloud-init parts for every EKS node: SOCI snapshotter install + its
  # containerd/kubelet NodeConfig fragment (shared with the Karpenter EC2NodeClass).
  soci_cloudinit_parts = [
    {
      content_type = "text/x-shellscript; charset=\"us-ascii\""
      content      = file("${path.module}/../../../platform/soci/install-soci.sh")
    },
    {
      content_type = "application/node.eks.aws"
      content      = file("${path.module}/../../../platform/soci/nodeconfig.yaml")
    },
  ]

  # Pod density on managed node groups with VPC CNI prefix delegation.
  system_nodeconfig_part = {
    content_type = "application/node.eks.aws"
    content      = <<-EOT
      ---
      apiVersion: node.eks.aws/v1alpha1
      kind: NodeConfig
      spec:
        kubelet:
          config:
            maxPods: 110
    EOT
  }

  node_cloudinit_parts = concat(local.soci_cloudinit_parts, [local.system_nodeconfig_part])

  router_port = 8080
}

module "network" {
  source = "../../modules/network"

  name     = local.name_prefix
  vpc_cidr = var.vpc_cidr
  azs      = local.azs
  tags     = local.tags
}

module "edge" {
  source = "../../modules/edge"

  name              = local.name_prefix
  region            = var.region
  hosted_zone_name  = var.hosted_zone_name
  api_hostname      = var.api_hostname
  vpc_id            = module.network.vpc_id
  vpc_cidr          = module.network.vpc_cidr
  public_subnet_ids = module.network.public_subnet_ids
  router_port       = local.router_port
  tags              = local.tags
}

module "regional" {
  source = "../../modules/regional"

  cluster_name        = "${local.name_prefix}-router"
  kubernetes_version  = var.kubernetes_version
  addon_versions      = var.addon_versions
  ami_release_version = var.ami_release_version

  vpc_id                   = module.network.vpc_id
  vpc_cidr                 = module.network.vpc_cidr
  node_subnet_ids          = module.network.private_subnet_ids
  control_plane_subnet_ids = module.network.private_subnet_ids

  system_instance_types = var.regional_system_instance_types
  node_cloudinit_parts  = local.node_cloudinit_parts
  admin_principal_arns  = var.operator_principal_arns

  alb_security_group_id = module.edge.alb_security_group_id
  router_port           = local.router_port

  ecr_namespace = var.name

  tags = local.tags
}

module "cell" {
  source   = "../../modules/cell"
  for_each = var.cells

  region                  = var.region
  availability_zone       = each.value.availability_zone
  cell_id                 = each.key
  inference_instance_type = each.value.inference_instance_type
  efa_enabled             = each.value.efa_enabled

  name_prefix         = local.name_prefix
  kubernetes_version  = var.kubernetes_version
  addon_versions      = var.addon_versions
  ami_release_version = var.ami_release_version

  vpc_id                   = module.network.vpc_id
  vpc_cidr                 = module.network.vpc_cidr
  cell_subnet_id           = module.network.private_subnet_ids_by_az[each.value.availability_zone]
  control_plane_subnet_ids = module.network.private_subnet_ids

  system_instance_types = var.cell_system_instance_types
  node_cloudinit_parts  = local.node_cloudinit_parts
  admin_principal_arns  = var.operator_principal_arns

  tags = local.tags
}

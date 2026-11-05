# One cell = one EKS cluster in one Availability Zone.
#
#   - EKS cluster + system managed node group in the cell AZ (eks-base)
#   - Karpenter IAM, SQS interruption queue and Pod Identity association
#   - Cluster placement group and EFA security group for inference nodes
#   - Pod Identity role for the AWS Load Balancer Controller (internal NLB)
#   - The inference EC2NodeClass and NodePool, rendered from
#     platform/karpenter/*.tftpl and output as one manifest for kubectl

data "aws_region" "current" {}

data "aws_ec2_instance_type" "inference" {
  instance_type = var.inference_instance_type
}

data "aws_ec2_instance_type_offerings" "inference_in_az" {
  location_type = "availability-zone"

  filter {
    name   = "instance-type"
    values = [var.inference_instance_type]
  }

  filter {
    name   = "location"
    values = [var.availability_zone]
  }
}

locals {
  cluster_name = "${var.name_prefix}-${var.cell_id}"

  # EFA layout: card 0 / device 0 is the ENA interface for IPv4 node and pod
  # traffic; every additional interface is EFA-only, up to the instance maximum.
  # For c8i.48xlarge this is a single EFA-only interface at card 0 / device 1.
  efa_interface_count = var.efa_enabled ? min(
    data.aws_ec2_instance_type.inference.efa_maximum_interfaces,
    data.aws_ec2_instance_type.inference.maximum_network_cards,
  ) : 0

  inference_network_interfaces = var.efa_enabled ? concat(
    [{ networkCardIndex = 0, deviceIndex = 0, interfaceType = "interface" }],
    local.efa_interface_count >= 1 ? [{ networkCardIndex = 0, deviceIndex = 1, interfaceType = "efa-only" }] : [],
    [for card in range(1, local.efa_interface_count) : { networkCardIndex = card, deviceIndex = 0, interfaceType = "efa-only" }],
  ) : []

  # Same AMI release as the system node groups: "1.37.1-20261031" -> "al2023@v20261031".
  ami_alias = "al2023@v${split("-", var.ami_release_version)[1]}"
}

################################################################################
# EKS cluster + system node group
################################################################################

module "cluster" {
  source = "../eks-base"

  cluster_name        = local.cluster_name
  kubernetes_version  = var.kubernetes_version
  addon_versions      = var.addon_versions
  ami_release_version = var.ami_release_version

  vpc_id = var.vpc_id
  # Nodes live only in the cell AZ; the control plane needs at least two AZs.
  node_subnet_ids          = [var.cell_subnet_id]
  control_plane_subnet_ids = var.control_plane_subnet_ids
  vpc_cidr                 = var.vpc_cidr

  system_instance_types         = var.system_instance_types
  system_node_min_size          = var.system_node_min_size
  system_node_desired_size      = var.system_node_desired_size
  system_node_max_size          = var.system_node_max_size
  system_node_volume_size_gib   = var.system_node_volume_size_gib
  system_node_volume_throughput = 500
  node_cloudinit_parts          = var.node_cloudinit_parts

  node_security_group_tags = {
    "karpenter.sh/discovery" = local.cluster_name
  }

  admin_principal_arns = var.admin_principal_arns
  tags                 = var.tags
}

################################################################################
# Karpenter (module defaults: Pod Identity association for kube-system/karpenter)
################################################################################

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "21.29.0"

  cluster_name = module.cluster.cluster_name

  iam_role_name            = "${local.cluster_name}-karpenter"
  iam_role_use_name_prefix = false

  # The controller policy is larger than the 6,144-character limit of a managed
  # IAM policy; an inline role policy allows 10,240 characters.
  enable_inline_policy = true

  node_iam_role_name            = "${local.cluster_name}-karpenter-node"
  node_iam_role_use_name_prefix = false
  node_iam_role_additional_policies = {
    ssm = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  queue_name = "${local.cluster_name}-karpenter"

  tags = var.tags
}

data "aws_partition" "current" {}

################################################################################
# Inference node placement and EFA security group
################################################################################

resource "aws_placement_group" "inference" {
  name     = "${local.cluster_name}-inference"
  strategy = "cluster"
  tags     = var.tags
}

# EFA requires a security group that allows all traffic to and from itself.
resource "aws_security_group" "efa" {
  name_prefix = "${local.cluster_name}-efa-"
  description = "EFA: all traffic to and from itself"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${local.cluster_name}-efa" })

  lifecycle {
    create_before_destroy = true

    precondition {
      condition     = var.region == data.aws_region.current.region
      error_message = "Cell region ${var.region} does not match the provider region ${data.aws_region.current.region}."
    }

    precondition {
      condition     = !var.efa_enabled || data.aws_ec2_instance_type.inference.efa_supported
      error_message = "efa_enabled is true but ${var.inference_instance_type} does not support EFA."
    }

    precondition {
      condition     = length(data.aws_ec2_instance_type_offerings.inference_in_az.instance_types) > 0
      error_message = "${var.inference_instance_type} is not offered in ${var.availability_zone}."
    }
  }
}

resource "aws_vpc_security_group_ingress_rule" "efa_self" {
  security_group_id            = aws_security_group.efa.id
  description                  = "All traffic from itself"
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.efa.id
}

resource "aws_vpc_security_group_egress_rule" "efa_self" {
  security_group_id            = aws_security_group.efa.id
  description                  = "All traffic to itself"
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.efa.id
}

################################################################################
# Pod Identity: AWS Load Balancer Controller
################################################################################

module "lbc_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.10.0"

  name            = "${local.cluster_name}-lbc"
  use_name_prefix = false

  attach_aws_lb_controller_policy = true
  # IAM policy names are account-wide: one policy per cluster.
  aws_lb_controller_policy_name = "${local.cluster_name}-lbc"

  associations = {
    this = {
      cluster_name    = module.cluster.cluster_name
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
    }
  }

  tags = var.tags
}

################################################################################
# Karpenter inference EC2NodeClass + NodePool (applied by scripts/41-*)
################################################################################

# SOCI on inference nodes only: the AMI's built-in snapshotter, enabled through
# nodeadm, plus the switch from parallel pull to lazy loading.
data "cloudinit_config" "inference" {
  gzip          = false
  base64_encode = false
  boundary      = "//"

  part {
    content_type = "application/node.eks.aws"
    content      = file("${var.platform_dir}/soci/nodeconfig.yaml")
  }

  part {
    content_type = "text/x-shellscript; charset=\"us-ascii\""
    content      = file("${var.platform_dir}/soci/lazy-loading.sh")
  }
}

locals {
  karpenter_manifests = join("\n---\n", [
    templatefile("${var.platform_dir}/karpenter/ec2nodeclass.yaml.tftpl", {
      node_role            = module.karpenter.node_iam_role_name
      ami_alias            = local.ami_alias
      subnet_id            = var.cell_subnet_id
      security_group_ids   = [module.cluster.node_security_group_id, aws_security_group.efa.id]
      placement_group_name = aws_placement_group.inference.name
      network_interfaces   = local.inference_network_interfaces
      cell_id              = var.cell_id
      user_data            = data.cloudinit_config.inference.rendered
    }),
    templatefile("${var.platform_dir}/karpenter/nodepool.yaml.tftpl", {
      cell_id           = var.cell_id
      availability_zone = var.availability_zone
      instance_type     = var.inference_instance_type
      cpu_limit         = var.inference_cpu_limit
    }),
  ])
}

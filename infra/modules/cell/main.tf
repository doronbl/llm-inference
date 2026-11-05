# One cell = one EKS cluster in one Availability Zone.
#
#   - System managed node group (in the cell AZ) for add-ons, Karpenter, the AWS
#     Load Balancer Controller and the Dynamo platform/frontend.
#   - Karpenter IAM/SQS resources (IRSA) for the AZ-pinned inference NodePool.
#     The NodePool/EC2NodeClass objects themselves are Kubernetes resources
#     applied from platform/karpenter/ with the values this module outputs.
#   - Cluster placement group and EFA security group for inference nodes.
#   - IRSA role for the AWS Load Balancer Controller (internal NLB in front of
#     the Dynamo frontend).

data "aws_partition" "current" {}

data "aws_ec2_instance_type" "inference" {
  region        = var.region
  instance_type = var.inference_instance_type
}

data "aws_ec2_instance_type_offerings" "inference_in_az" {
  region        = var.region
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
}

################################################################################
# EKS cluster + system node group
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.29.0"

  region             = var.region
  name               = local.cluster_name
  kubernetes_version = var.kubernetes_version

  endpoint_public_access  = false
  endpoint_private_access = true

  vpc_id = var.vpc_id
  # Nodes live only in the cell AZ; the control plane needs at least two AZs.
  subnet_ids               = [var.cell_subnet_id]
  control_plane_subnet_ids = var.control_plane_subnet_ids

  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true
  access_entries = {
    for i, arn in var.admin_principal_arns : "admin-${i}" => {
      principal_arn = arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  enable_irsa = true

  addons = {
    vpc-cni = {
      addon_version  = var.addon_versions["vpc-cni"]
      most_recent    = false
      before_compute = true
      configuration_values = jsonencode({
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
    kube-proxy = {
      addon_version  = var.addon_versions["kube-proxy"]
      most_recent    = false
      before_compute = true
    }
    coredns = {
      addon_version = var.addon_versions["coredns"]
      most_recent   = false
    }
  }

  security_group_additional_rules = {
    ingress_vpc_https = {
      description = "Kubernetes API from inside the VPC (operator SSM tunnel)"
      protocol    = "tcp"
      from_port   = 443
      to_port     = 443
      type        = "ingress"
      cidr_blocks = [var.vpc_cidr]
    }
  }

  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node, all ports (Dynamo request/event planes, NATS)"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
  }

  # Karpenter discovers nothing by tag; the EC2NodeClass selects subnet and
  # security groups by ID. The tag is kept for operators and tooling.
  node_security_group_tags = {
    "karpenter.sh/discovery" = local.cluster_name
  }

  eks_managed_node_groups = {
    system = {
      ami_type            = "AL2023_x86_64_STANDARD"
      ami_release_version = var.ami_release_version
      instance_types      = var.system_instance_types
      capacity_type       = "ON_DEMAND"

      min_size     = var.system_node_min_size
      max_size     = var.system_node_max_size
      desired_size = var.system_node_desired_size

      subnet_ids = [var.cell_subnet_id]

      labels = {
        "llm-inference/node-class" = "system"
      }

      cloudinit_pre_nodeadm = var.node_cloudinit_parts

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = var.system_node_volume_size_gib
            volume_type           = "gp3"
            throughput            = 500
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      iam_role_additional_policies = {
        ssm = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }
    }
  }

  tags = var.tags
}

################################################################################
# Karpenter (IRSA)
################################################################################

# Replaces the Pod Identity trust statement of the Karpenter submodule (same
# Sid) with an IRSA web-identity trust for kube-system:karpenter.
data "aws_iam_policy_document" "karpenter_irsa_trust" {
  statement {
    sid     = "PodIdentity"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:kube-system:karpenter"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "21.29.0"

  region       = var.region
  cluster_name = module.eks.cluster_name

  create_pod_identity_association           = false
  iam_role_name                             = "${local.cluster_name}-karpenter"
  iam_role_use_name_prefix                  = false
  iam_role_override_assume_policy_documents = [data.aws_iam_policy_document.karpenter_irsa_trust.json]

  node_iam_role_name            = "${local.cluster_name}-karpenter-node"
  node_iam_role_use_name_prefix = false
  node_iam_role_additional_policies = {
    ssm = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  queue_name = "${local.cluster_name}-karpenter"

  tags = var.tags
}

################################################################################
# Inference node placement and EFA security group
################################################################################

resource "aws_placement_group" "inference" {
  region   = var.region
  name     = "${local.cluster_name}-inference"
  strategy = "cluster"
  tags     = var.tags
}

# EFA requires a security group that allows all traffic to and from itself.
resource "aws_security_group" "efa" {
  region      = var.region
  name_prefix = "${local.cluster_name}-efa-"
  description = "EFA: all traffic to and from itself"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${local.cluster_name}-efa" })

  lifecycle {
    create_before_destroy = true

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
  region                       = var.region
  security_group_id            = aws_security_group.efa.id
  description                  = "All traffic from itself"
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.efa.id
}

resource "aws_vpc_security_group_egress_rule" "efa_self" {
  region                       = var.region
  security_group_id            = aws_security_group.efa.id
  description                  = "All traffic to itself"
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.efa.id
}

################################################################################
# IRSA: AWS Load Balancer Controller
################################################################################

module "lbc_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.8.2"

  name            = "${local.cluster_name}-lbc"
  use_name_prefix = false

  attach_load_balancer_controller_policy = true

  oidc_providers = {
    this = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }

  tags = var.tags
}

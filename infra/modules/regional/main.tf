# Regional router cluster: one EKS cluster per Region (private API endpoint),
# a small system managed node group that runs the router pods and add-ons,
# the ECR repositories the platform owns, and the IRSA role of the AWS Load
# Balancer Controller (which binds router pods to the ALB target group).

data "aws_partition" "current" {}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.29.0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  # Private API endpoint only; operators come in through an SSM tunnel.
  endpoint_public_access  = false
  endpoint_private_access = true

  vpc_id                   = var.vpc_id
  subnet_ids               = var.node_subnet_ids
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

  # The operator instance lives inside the VPC and reaches the private endpoint.
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
      description = "Node to node, all ports"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
    ingress_alb_router = {
      description              = "Public ALB to router pods (IP targets)"
      protocol                 = "tcp"
      from_port                = var.router_port
      to_port                  = var.router_port
      type                     = "ingress"
      source_security_group_id = var.alb_security_group_id
    }
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

      subnet_ids = var.node_subnet_ids

      labels = {
        "llm-inference/node-class" = "system"
      }

      # SOCI snapshotter + kubelet settings, merged with the EKS-generated NodeConfig.
      cloudinit_pre_nodeadm = var.node_cloudinit_parts

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = var.system_node_volume_size_gib
            volume_type           = "gp3"
            throughput            = 250
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
# ECR repositories owned by the platform
################################################################################

resource "aws_ecr_repository" "this" {
  for_each = toset(var.ecr_repository_names)

  name                 = "${var.ecr_namespace}/${each.key}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = var.tags
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the 30 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 30
      }
      action = { type = "expire" }
    }]
  })
}

################################################################################
# IRSA: AWS Load Balancer Controller
################################################################################

module "lbc_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.8.2"

  name            = "${var.cluster_name}-lbc"
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

# Regional router cluster: one EKS cluster per Region (private API endpoint),
# a small system node group that runs the router pods and add-ons, the ECR
# repositories the platform owns, and the Pod Identity role of the AWS Load
# Balancer Controller (which binds router pods to the ALB target group).

module "cluster" {
  source = "../eks-base"

  cluster_name        = var.cluster_name
  kubernetes_version  = var.kubernetes_version
  addon_versions      = var.addon_versions
  ami_release_version = var.ami_release_version

  vpc_id                   = var.vpc_id
  vpc_cidr                 = var.vpc_cidr
  node_subnet_ids          = var.node_subnet_ids
  control_plane_subnet_ids = var.control_plane_subnet_ids

  system_instance_types         = var.system_instance_types
  system_node_min_size          = var.system_node_min_size
  system_node_desired_size      = var.system_node_desired_size
  system_node_max_size          = var.system_node_max_size
  system_node_volume_size_gib   = var.system_node_volume_size_gib
  system_node_volume_throughput = 250
  node_cloudinit_parts          = var.node_cloudinit_parts
  system_node_tags              = { "llm-inference/role" = "router" }

  node_security_group_additional_rules = {
    ingress_alb_router = {
      description              = "Public ALB to router pods (IP targets)"
      protocol                 = "tcp"
      from_port                = var.router_port
      to_port                  = var.router_port
      type                     = "ingress"
      source_security_group_id = var.alb_security_group_id
    }
  }

  admin_principal_arns = var.admin_principal_arns
  tags                 = var.tags
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
# Pod Identity: AWS Load Balancer Controller
################################################################################

module "lbc_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.10.0"

  name            = "${var.cluster_name}-lbc"
  use_name_prefix = false

  attach_aws_lb_controller_policy = true
  # IAM policy names are account-wide: one policy per cluster.
  aws_lb_controller_policy_name = "${var.cluster_name}-lbc"

  associations = {
    this = {
      cluster_name    = module.cluster.cluster_name
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
    }
  }

  tags = var.tags
}

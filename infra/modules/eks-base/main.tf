# Thin wrapper around terraform-aws-modules/eks with the settings every cluster
# of the platform shares (regional router cluster and cells):
#
#   - private API endpoint only, reachable from inside the VPC
#   - EKS access entries (API mode) for the Terraform caller and operators
#   - pinned add-ons: VPC CNI (prefix delegation), kube-proxy, CoreDNS and the
#     EKS Pod Identity Agent (IAM for in-cluster controllers)
#   - one "system" managed node group (EKS-optimized AL2023, on demand)
#
# Callers pass only what differs: subnets, node group size and disk, extra
# security group rules.

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

  # In-cluster controllers use EKS Pod Identity; no OIDC provider is needed.
  enable_irsa = false

  addons = {
    eks-pod-identity-agent = {
      addon_version  = var.addon_versions["eks-pod-identity-agent"]
      most_recent    = false
      before_compute = true
    }
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

  node_security_group_additional_rules = merge(
    {
      ingress_self_all = {
        description = "Node to node, all ports"
        protocol    = "-1"
        from_port   = 0
        to_port     = 0
        type        = "ingress"
        self        = true
      }
    },
    var.node_security_group_additional_rules,
  )

  node_security_group_tags = var.node_security_group_tags

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

      # Instance and volume tags. The default Name is the node group key
      # ("system") on every cluster; name the nodes after their cluster.
      launch_template_tags = merge(var.system_node_tags, {
        Name                       = "${var.cluster_name}-system"
        "llm-inference/cluster"    = var.cluster_name
        "llm-inference/node-class" = "system"
      })

      cloudinit_pre_nodeadm = var.node_cloudinit_parts

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = var.system_node_volume_size_gib
            volume_type           = "gp3"
            throughput            = var.system_node_volume_throughput
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

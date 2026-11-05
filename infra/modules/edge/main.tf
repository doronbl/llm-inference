# Public entry point for one Region:
#   ACM certificate (DNS-validated) -> public ALB (HTTPS only, JWT verification)
#   -> IP target group (router pods are registered by the AWS Load Balancer
#   Controller through a TargetGroupBinding).
# Plus the Cognito user pool that issues the access tokens and the Route 53
# latency-based alias record for the API hostname.

data "aws_route53_zone" "this" {
  name         = var.hosted_zone_name
  private_zone = false
}

################################################################################
# TLS certificate
################################################################################

resource "aws_acm_certificate" "api" {
  domain_name       = var.api_hostname
  validation_method = "DNS"
  tags              = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

# The certificate covers a single name, so it has exactly one validation record.
locals {
  acm_validation = one(aws_acm_certificate.api.domain_validation_options)
}

resource "aws_route53_record" "acm_validation" {
  zone_id         = data.aws_route53_zone.this.zone_id
  name            = local.acm_validation.resource_record_name
  type            = local.acm_validation.resource_record_type
  records         = [local.acm_validation.resource_record_value]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "api" {
  certificate_arn         = aws_acm_certificate.api.arn
  validation_record_fqdns = [aws_route53_record.acm_validation.fqdn]
}

################################################################################
# Cognito (OAuth 2.0 client-credentials only)
################################################################################

resource "random_string" "cognito_domain_suffix" {
  length  = 8
  lower   = true
  upper   = false
  numeric = true
  special = false
}

resource "aws_cognito_user_pool" "this" {
  name = "${var.name}-api"

  # Machine-to-machine only: nobody signs up or signs in.
  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  deletion_protection = "INACTIVE"
  tags                = var.tags
}

resource "aws_cognito_resource_server" "api" {
  user_pool_id = aws_cognito_user_pool.this.id
  identifier   = var.resource_server_identifier
  name         = "${var.name}-api"

  scope {
    scope_name        = var.scope_name
    scope_description = "Call the inference API"
  }
}

resource "aws_cognito_user_pool_client" "m2m" {
  name         = "${var.name}-m2m"
  user_pool_id = aws_cognito_user_pool.this.id

  generate_secret = true

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_scopes                 = aws_cognito_resource_server.api.scope_identifiers

  # Only the minimum non-interactive auth flow; no user sign-in flows.
  explicit_auth_flows = ["ALLOW_REFRESH_TOKEN_AUTH"]

  access_token_validity = var.access_token_validity_minutes
  token_validity_units {
    access_token = "minutes"
  }

  prevent_user_existence_errors = "ENABLED"
}

# The domain exists only to serve the OAuth 2.0 token endpoint.
resource "aws_cognito_user_pool_domain" "this" {
  domain       = "${var.cognito_domain_prefix}-${random_string.cognito_domain_suffix.result}"
  user_pool_id = aws_cognito_user_pool.this.id
}

locals {
  issuer         = "https://${aws_cognito_user_pool.this.endpoint}"
  jwks_url       = "${local.issuer}/.well-known/jwks.json"
  token_endpoint = "https://${aws_cognito_user_pool_domain.this.domain}.auth.${var.region}.amazoncognito.com/oauth2/token"
  required_scope = "${var.resource_server_identifier}/${var.scope_name}"
}

################################################################################
# Public ALB (HTTPS only)
################################################################################

resource "aws_security_group" "alb" {
  name_prefix = "${var.name}-alb-"
  description = "Public ALB: HTTPS in from the internet, router traffic out to the VPC"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-alb" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from the internet"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

# The jwt-validation action fetches the signing keys from the public Cognito
# JWKS endpoint through the ALB's own network interfaces. Without this rule
# every request fails with 500 at the ALB. Cognito has no fixed IP ranges or
# managed prefix list, so the destination is any address on 443.
resource "aws_vpc_security_group_egress_rule" "alb_jwks" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS to the Cognito JWKS endpoint (JWT validation)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_router" {
  security_group_id = aws_security_group.alb.id
  description       = "To router pods (IP targets)"
  ip_protocol       = "tcp"
  from_port         = var.router_port
  to_port           = var.router_port
  cidr_ipv4         = var.vpc_cidr
}

resource "aws_lb" "this" {
  name               = substr("${var.name}-api", 0, 32)
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  idle_timeout               = var.alb_idle_timeout_seconds
  drop_invalid_header_fields = true
  enable_deletion_protection = false

  tags = var.tags
}

resource "aws_lb_target_group" "router" {
  name                 = substr("${var.name}-router", 0, 32)
  vpc_id               = var.vpc_id
  target_type          = "ip"
  protocol             = "HTTP"
  port                 = var.router_port
  deregistration_delay = 300

  health_check {
    enabled             = true
    protocol            = "HTTP"
    path                = "/healthz"
    port                = "traffic-port"
    matcher             = "200"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
  }

  tags = var.tags
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = var.ssl_policy
  certificate_arn   = aws_acm_certificate_validation.api.certificate_arn

  # 1. Verify the Cognito access token (signature via JWKS, iss, exp, scope).
  default_action {
    type  = "jwt-validation"
    order = 1

    jwt_validation {
      issuer        = local.issuer
      jwks_endpoint = local.jwks_url

      additional_claim {
        name   = "token_use"
        format = "single-string"
        values = ["access"]
      }

      additional_claim {
        name   = "scope"
        format = "space-separated-values"
        values = [local.required_scope]
      }
    }
  }

  # 2. Forward verified requests to the router pods.
  default_action {
    type             = "forward"
    order            = 2
    target_group_arn = aws_lb_target_group.router.arn
  }

  tags = var.tags
}

################################################################################
# DNS: latency-based alias record (one record per Region on the same name)
################################################################################

resource "aws_route53_record" "api" {
  zone_id        = data.aws_route53_zone.this.zone_id
  name           = var.api_hostname
  type           = "A"
  set_identifier = var.region

  latency_routing_policy {
    region = var.region
  }

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}

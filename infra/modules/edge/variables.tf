variable "name" {
  description = "Name prefix for edge resources."
  type        = string
}

variable "region" {
  description = "AWS Region of this entry point (used for the latency record and the Cognito domain)."
  type        = string
}

variable "hosted_zone_name" {
  description = "Name of the existing public Route 53 hosted zone that holds api_hostname."
  type        = string
}

variable "api_hostname" {
  description = "Fully qualified API hostname, inside hosted_zone_name."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR (the ALB may only send traffic into the VPC)."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnets for the ALB (at least two AZs)."
  type        = list(string)
}

variable "router_port" {
  description = "Container port of the router pods (IP targets)."
  type        = number
  default     = 8080
}

variable "alb_idle_timeout_seconds" {
  description = "ALB idle timeout; long enough for long SSE streams."
  type        = number
  default     = 3600
}

variable "ssl_policy" {
  description = "ALB TLS security policy (TLS 1.2 and 1.3 only)."
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-2021-06"
}

variable "cognito_domain_prefix" {
  description = "Fixed prefix of the Cognito domain; a random suffix is appended."
  type        = string
  default     = "llm-inference"
}

variable "resource_server_identifier" {
  description = "Identifier of the Cognito resource server; the scope is <identifier>/<scope_name>."
  type        = string
  default     = "llm-api"
}

variable "scope_name" {
  description = "Custom scope required to call the API."
  type        = string
  default     = "invoke"
}

variable "access_token_validity_minutes" {
  description = "Lifetime of issued access tokens, in minutes."
  type        = number
  default     = 60
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}

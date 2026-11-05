terraform {
  required_version = "~> 1.17.0"

  # Local state (terraform.tfstate in this directory, git-ignored).

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.72.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.9.1"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "4.4.2"
    }
    time = {
      source  = "hashicorp/time"
      version = "0.14.2"
    }
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "2.4.1"
    }
    null = {
      source  = "hashicorp/null"
      version = "3.3.2"
    }
  }
}

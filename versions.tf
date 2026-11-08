terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
  }

  # Remote state backend (S3 with native lockfile; no DynamoDB table).
  # Backend blocks cannot reference variables, so bucket and region are supplied
  # at init time from backend.hcl (git-ignored; `make bootstrap-up` generates it
  # from the bootstrap outputs, or copy backend.hcl.example):
  #   terraform init -backend-config=backend.hcl
  backend "s3" {
    key          = "eks-platform/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

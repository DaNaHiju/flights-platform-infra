terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Remote state backend. Backend blocks cannot reference variables or locals,
  # so these values mirror the outputs of bootstrap/ (see bootstrap/README.md).
  # Run `terraform apply` in bootstrap/ BEFORE running `terraform init` here.
  backend "s3" {
    bucket         = "flights-tfstate-565923528020"
    key            = "eks-platform/terraform.tfstate"
    region         = "eu-north-1"
    dynamodb_table = "flights-tf-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.app_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

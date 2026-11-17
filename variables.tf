variable "app_name" {
  description = "Application name used across all resources"
  type        = string
  default     = "flights"
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "eu-north-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "single_nat" {
  description = "true: one NAT gateway shared by both AZs (cheap, lab). false: one NAT per AZ."
  type        = bool
  default     = true
}

# ── EKS ──────────────────────────────────────────────────────────────────────

variable "kubernetes_version" {
  description = "EKS Kubernetes version (must be in standard support; Istio 1.30 supports 1.32-1.36)"
  type        = string
  default     = "1.35"
}

variable "public_access_cidrs" {
  description = "CIDRs allowed to reach the PUBLIC EKS API endpoint. No default on purpose: set it in terraform.tfvars (git-ignored)."
  type        = list(string)

  validation {
    condition     = length(var.public_access_cidrs) > 0 && !contains(var.public_access_cidrs, "0.0.0.0/0")
    error_message = "public_access_cidrs must be non-empty and must not contain 0.0.0.0/0."
  }
}

variable "system_node_instance_type" {
  description = "Instance type for the system node group (platform components)"
  type        = string
  default     = "m7i-flex.large"

  validation {
    condition     = contains(local.free_tier_instance_types, var.system_node_instance_type)
    error_message = "Instance type must be free-tier eligible in eu-north-1: ${join(", ", local.free_tier_instance_types)}."
  }
}

variable "system_node_min" {
  description = "Minimum number of system nodes"
  type        = number
  default     = 2
}

variable "system_node_desired" {
  description = "Initial desired number of system nodes"
  type        = number
  default     = 2
}

variable "system_node_max" {
  description = "Maximum number of system nodes"
  type        = number
  default     = 3
}

variable "app_node_instance_type" {
  description = "Instance type for the app node group (workloads, tainted workload=app:NoSchedule)"
  type        = string
  default     = "m7i-flex.large"

  validation {
    condition     = contains(local.free_tier_instance_types, var.app_node_instance_type)
    error_message = "Instance type must be free-tier eligible in eu-north-1: ${join(", ", local.free_tier_instance_types)}."
  }
}

variable "app_node_min" {
  description = "Minimum number of app nodes"
  type        = number
  default     = 2
}

variable "app_node_desired" {
  description = "Initial desired number of app nodes (cluster-autoscaler changes it afterwards)"
  type        = number
  default     = 2
}

variable "app_node_max" {
  description = "Maximum number of app nodes"
  type        = number
  default     = 4
}

# ── Registry, secrets, CI ────────────────────────────────────────────────────

variable "ecr_repositories" {
  description = "ECR repositories to create (one per service image)"
  type        = list(string)
  default     = ["flights-api", "flights-worker", "flights-web"]
}

variable "db_secret_name" {
  description = "Secrets Manager secret holding the Postgres credentials (keys DB_USER, DB_PASSWORD). Must stay under flights/eks/ to match the ESO policy."
  type        = string
  default     = "flights/eks/db"

  validation {
    condition     = startswith(var.db_secret_name, "flights/eks/")
    error_message = "db_secret_name must start with flights/eks/ (the ESO role is limited to that prefix)."
  }
}

variable "db_user" {
  description = "Postgres user stored in the secret. Must equal postgresql.auth.username in the chart values."
  type        = string
  default     = "flights"
}

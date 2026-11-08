variable "app_name" {
  description = "Application name used across all resources"
  type        = string
  default     = "flights-api"
}

variable "project" {
  description = "Value of the common Project tag applied to every resource (used by make check-orphans)"
  type        = string
  default     = "flights-platform"
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
  default     = "us-east-1"
}

variable "docker_image" {
  description = "Full Docker image reference (registry/name:tag)"
  type        = string
  default     = "myrepo/flights-api:latest"
}

# AWS Free Plan only allows these EC2 types; anything else fails at launch time,
# so reject it at plan time instead.
variable "system_instance_type" {
  description = "EC2 instance type for the system node group (Free Plan types only)"
  type        = string
  default     = "t3.small"

  validation {
    condition     = contains(["t3.micro", "t3.small", "t4g.micro", "t4g.small", "c7i-flex.large", "m7i-flex.large"], var.system_instance_type)
    error_message = "system_instance_type must be a Free Plan type: t3.micro, t3.small, t4g.micro, t4g.small, c7i-flex.large, m7i-flex.large."
  }
}

variable "system_desired_node_count" {
  description = "Desired number of system nodes"
  type        = number
  default     = 2
}

variable "system_min_node_count" {
  description = "Minimum number of system nodes"
  type        = number
  default     = 1
}

variable "system_max_node_count" {
  description = "Maximum number of system nodes"
  type        = number
  default     = 3
}

variable "app_instance_type" {
  description = "EC2 instance type for the app node group (Free Plan types only)"
  type        = string
  default     = "m7i-flex.large"

  validation {
    condition     = contains(["t3.micro", "t3.small", "t4g.micro", "t4g.small", "c7i-flex.large", "m7i-flex.large"], var.app_instance_type)
    error_message = "app_instance_type must be a Free Plan type: t3.micro, t3.small, t4g.micro, t4g.small, c7i-flex.large, m7i-flex.large."
  }
}

variable "app_desired_node_count" {
  description = "Desired number of app nodes"
  type        = number
  default     = 1
}

variable "app_min_node_count" {
  description = "Minimum number of app nodes"
  type        = number
  default     = 1
}

variable "app_max_node_count" {
  description = "Maximum number of app nodes"
  type        = number
  default     = 2
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "alert_email" {
  description = "Email address for budget and cost alerts (required)"
  type        = string

  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.alert_email))
    error_message = "alert_email must be a valid email address."
  }
}

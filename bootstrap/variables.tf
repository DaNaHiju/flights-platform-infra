variable "project" {
  description = "Project name used to build the state bucket name"
  type        = string
  default     = "flights-platform"
}

variable "aws_region" {
  description = "AWS region for the backend resources (S3 bucket)"
  type        = string
  default     = "us-east-1"
}

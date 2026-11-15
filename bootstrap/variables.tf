variable "region" {
  description = "AWS region for the backend resources (S3 bucket + DynamoDB table)"
  type        = string
  default     = "eu-north-1"
}

output "state_bucket_name" {
  description = "Name of the S3 bucket holding Terraform state"
  value       = aws_s3_bucket.tfstate.id
}

output "aws_region" {
  description = "Region of the state bucket (use it as the backend region)"
  value       = var.aws_region
}

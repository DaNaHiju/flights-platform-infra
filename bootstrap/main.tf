# This folder intentionally uses LOCAL state: it creates the S3 bucket and
# DynamoDB table that the main config's remote backend depends on, so it
# cannot itself depend on that backend (bootstrap chicken-and-egg problem).

data "aws_caller_identity" "current" {}

# ── S3 bucket for Terraform state ────────────────────────────────────────────
# Cost note: state files are a few KB each; S3 storage + request costs for this
# stay well within the AWS free tier.

resource "aws_s3_bucket" "tfstate" {
  bucket = "flights-tfstate-${data.aws_caller_identity.current.account_id}"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── DynamoDB table for state locking ─────────────────────────────────────────
# Cost note: PAY_PER_REQUEST billing means we only pay per lock/unlock request
# (a handful per terraform run) — effectively free tier.

resource "aws_dynamodb_table" "tflock" {
  name         = "flights-tf-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

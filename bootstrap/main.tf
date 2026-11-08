# This folder intentionally uses LOCAL state: it creates the S3 bucket that the
# root configuration's remote backend depends on, so it cannot itself depend on
# that backend (bootstrap chicken-and-egg problem). Keep bootstrap/terraform.tfstate
# safe (it is git-ignored): without it you cannot manage or destroy the bucket.
#
# State locking uses S3 native lockfiles (use_lockfile = true in the root
# backend), so no DynamoDB table is needed.

data "aws_caller_identity" "current" {}

# ── S3 bucket for Terraform state ────────────────────────────────────────────
# The account id suffix keeps the (globally unique) bucket name collision-free.
# Cost note: state files are a few KB each; S3 storage + request costs stay
# within the free tier (or a few cents/month after it expires).

resource "aws_s3_bucket" "tfstate" {
  bucket = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"

  # `make bootstrap-down` must be able to remove a bucket that holds versioned
  # state objects. Destroying bootstrap deletes ALL Terraform state: the Makefile
  # asks for explicit confirmation first.
  force_destroy = true

  tags = {
    Project   = "${var.project}-bootstrap"
    ManagedBy = "terraform"
    Purpose   = "terraform-remote-state"
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

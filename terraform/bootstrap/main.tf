# ==============================================================================
# BOOTSTRAP: Remote State Backend
# ==============================================================================
# This configuration creates the S3 bucket and DynamoDB table that Terraform
# uses to store its state file remotely and to lock state during applies.
#
# IMPORTANT: This is a "chicken-and-egg" problem. You cannot store the state of
# the backend resources in the backend itself before it exists. Therefore, this
# bootstrap directory uses LOCAL state for its very first apply. After it runs
# once, these resources persist and rarely change.
#
# Run this ONCE manually before the GitHub Actions pipeline can work:
#   cd terraform/bootstrap
#   terraform init
#   terraform apply
# ==============================================================================

terraform {
  # Pin the required Terraform CLI version. Pinning avoids surprises when a new
  # Terraform release changes behavior. The "~>" operator allows patch/minor
  # bumps within 1.x but blocks a jump to 2.0.
  required_version = "~> 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

# The AWS provider authenticates using credentials supplied by the environment.
# In GitHub Actions we use OIDC (no long-lived keys). Locally it uses your
# AWS CLI profile / environment variables.
provider "aws" {
  region = var.aws_region

  # Apply a consistent set of tags to every resource this provider creates.
  # Centralized tagging is a best practice for cost allocation and ownership.
  default_tags {
    tags = {
      ManagedBy   = "Terraform"
      Project     = var.project_name
      Environment = "shared"
      Purpose     = "tf-remote-state"
    }
  }
}

# ------------------------------------------------------------------------------
# S3 bucket that holds the Terraform state file (terraform.tfstate).
# ------------------------------------------------------------------------------
resource "aws_s3_bucket" "tf_state" {
  bucket = "${var.project_name}-tfstate-${var.aws_account_id}"

  # Safety net: prevent `terraform destroy` from accidentally deleting the
  # bucket that holds ALL of your state. Removing state is catastrophic.
  lifecycle {
    prevent_destroy = true
  }
}

# Turn on versioning so every change to the state file is retained. If a state
# file gets corrupted or a bad apply happens, you can roll back to a prior
# version of the object.
resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Encrypt the state at rest. State files frequently contain secrets (database
# passwords, tokens), so server-side encryption is mandatory.
resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

# Block ALL public access to the state bucket. State should never be public.
resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ------------------------------------------------------------------------------
# DynamoDB table used for STATE LOCKING.
# ------------------------------------------------------------------------------
# When Terraform runs, it writes a lock item to this table. If a second run
# starts while the first holds the lock, the second waits or fails. This stops
# two pipelines from corrupting state by writing at the same time.
resource "aws_dynamodb_table" "tf_lock" {
  name         = "${var.project_name}-tflock"
  billing_mode = "PAY_PER_REQUEST" # No capacity planning needed; cheap for locks.
  hash_key     = "LockID"          # Terraform requires this exact attribute name.

  attribute {
    name = "LockID"
    type = "S"
  }
}

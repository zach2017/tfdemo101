# ==============================================================================
# BOOTSTRAP: Input Variables
# ==============================================================================
# Variables let you parameterize the configuration without editing the .tf
# files. Values can come from terraform.tfvars, -var flags, or TF_VAR_ env vars.
# ==============================================================================

variable "aws_region" {
  description = "AWS region where the state bucket and lock table live."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short, lowercase project identifier used to name resources."
  type        = string
  default     = "eks-platform"

  # Validation blocks catch bad input early, before any API calls are made.
  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.project_name))
    error_message = "project_name must be lowercase alphanumeric with hyphens only."
  }
}

variable "aws_account_id" {
  description = "Your 12-digit AWS account ID. Used to make the bucket name globally unique."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must be exactly 12 digits."
  }
}

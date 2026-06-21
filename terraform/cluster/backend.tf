# ==============================================================================
# CLUSTER: Remote State Backend Configuration
# ==============================================================================
# This tells Terraform to store THIS directory's state in the S3 bucket and to
# lock using the DynamoDB table created by the bootstrap step.
#
# NOTE: Backend blocks cannot use variables. The values must be hardcoded here
# OR passed at init time via `-backend-config` flags. Our GitHub Actions
# pipeline passes them via flags so this file stays free of account-specifics.
#
# To init locally:
#   terraform init \
#     -backend-config="bucket=eks-platform-tfstate-123456789012" \
#     -backend-config="dynamodb_table=eks-platform-tflock" \
#     -backend-config="key=cluster/terraform.tfstate" \
#     -backend-config="region=us-east-1"
# ==============================================================================

terraform {
  required_version = "~> 1.9"

  backend "s3" {
    # The "key" is the path of the state object WITHIN the bucket. Giving the
    # cluster its own key (cluster/terraform.tfstate) keeps it isolated from
    # node-group and tenant state files you will add later under their own keys.
    key     = "cluster/terraform.tfstate"
    encrypt = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    # The Kubernetes and Helm providers are needed because the EKS module wires
    # cluster authentication (the aws-auth configmap / access entries) for you.
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

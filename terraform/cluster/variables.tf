# ==============================================================================
# CLUSTER: Input Variables
# ==============================================================================

variable "aws_region" {
  description = "AWS region to deploy the EKS cluster into."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short project identifier, used in resource names and tags."
  type        = string
  default     = "eks-platform"
}

variable "environment" {
  description = "Deployment environment (e.g. dev, staging, prod)."
  type        = string
  default     = "dev"
}

# ------------------------------------------------------------------------------
# Kubernetes version
# ------------------------------------------------------------------------------
variable "kubernetes_version" {
  description = "EKS Kubernetes control-plane version. Upgrade one minor version at a time."
  type        = string
  default     = "1.30"
}

# ------------------------------------------------------------------------------
# Networking
# ------------------------------------------------------------------------------
variable "vpc_cidr" {
  description = "CIDR block for the VPC. Must be large enough for all pods/nodes."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones_count" {
  description = "Number of AZs to spread subnets across. 3 is recommended for HA."
  type        = number
  default     = 3

  validation {
    condition     = var.availability_zones_count >= 2 && var.availability_zones_count <= 4
    error_message = "Use between 2 and 4 availability zones."
  }
}

# ------------------------------------------------------------------------------
# Baseline (system) managed node group
# ------------------------------------------------------------------------------
# This cluster ships with ONE small "system" node group to run core add-ons
# (CoreDNS, etc.). Application and per-tenant node groups are intentionally
# left OUT of this directory — you will add them later under
# terraform/node-groups and terraform/tenants. See the README.
variable "system_node_instance_types" {
  description = "Instance types for the baseline system node group."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "system_node_desired_size" {
  description = "Desired number of nodes in the system node group."
  type        = number
  default     = 2
}

variable "system_node_min_size" {
  description = "Minimum number of nodes in the system node group."
  type        = number
  default     = 1
}

variable "system_node_max_size" {
  description = "Maximum number of nodes in the system node group."
  type        = number
  default     = 3
}

# ------------------------------------------------------------------------------
# Access control
# ------------------------------------------------------------------------------
variable "cluster_admin_role_arns" {
  description = "List of IAM role ARNs that should get cluster-admin via EKS access entries."
  type        = list(string)
  default     = []
}

variable "endpoint_public_access" {
  description = "Whether the EKS API endpoint is reachable from the public internet. For prod, prefer false + a bastion/VPN."
  type        = bool
  default     = true
}

variable "endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public API endpoint. Lock this down to your office/VPN IPs."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ==============================================================================
# CLUSTER: Outputs
# ==============================================================================
# These outputs are the "contract" that future directories (node-groups,
# tenants) consume. They read them via a terraform_remote_state data source
# pointed at this cluster's state file. Exposing IDs/ARNs here means the
# downstream code never has to hardcode them.
# ==============================================================================

output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Endpoint URL for the EKS Kubernetes API."
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 CA cert used by kubectl/clients to trust the API."
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "cluster_security_group_id" {
  description = "Security group ID attached to the control plane."
  value       = module.eks.cluster_security_group_id
}

output "node_security_group_id" {
  description = "Security group ID shared by managed nodes. Future node groups attach to this."
  value       = module.eks.node_security_group_id
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC provider for IRSA. Future tenant roles trust this."
  value       = module.eks.oidc_provider_arn
}

output "vpc_id" {
  description = "VPC ID the cluster runs in."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs. Future node groups launch here."
  value       = module.vpc.private_subnets
}

output "region" {
  description = "AWS region of the cluster."
  value       = var.aws_region
}

# A ready-to-run command so a human can immediately get kubectl access.
output "configure_kubectl" {
  description = "Run this to point kubectl at the new cluster."
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

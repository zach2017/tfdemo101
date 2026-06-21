# ==============================================================================
# BOOTSTRAP: Outputs
# ==============================================================================
# Outputs print useful values after apply. You will copy these into the
# backend configuration of the cluster directory.
# ==============================================================================

output "state_bucket_name" {
  description = "Name of the S3 bucket holding Terraform state. Put this in cluster/backend.tf."
  value       = aws_s3_bucket.tf_state.id
}

output "lock_table_name" {
  description = "Name of the DynamoDB lock table. Put this in cluster/backend.tf."
  value       = aws_dynamodb_table.tf_lock.name
}

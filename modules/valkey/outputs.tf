output "primary_endpoint" {
  value = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "auth_token" {
  value     = random_password.auth.result
  sensitive = true
}

output "member_clusters" {
  description = "Node ids, for CloudWatch dimensions."
  value       = aws_elasticache_replication_group.this.member_clusters
}

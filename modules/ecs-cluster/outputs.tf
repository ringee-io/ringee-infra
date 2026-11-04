output "arn" {
  value = aws_ecs_cluster.this.arn
}

output "name" {
  value = aws_ecs_cluster.this.name
}

output "namespace_id" {
  value = aws_service_discovery_private_dns_namespace.this.id
}

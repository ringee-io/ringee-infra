# Container Insights stays off at first (plan §5.4): it bills per metric and the
# alarms in modules/observability use the free service metrics.

resource "aws_ecs_cluster" "this" {
  name = var.name

  setting {
    name  = "containerInsights"
    value = "disabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

# temporal.<internal_domain>:7233 for the API and the worker.
resource "aws_service_discovery_private_dns_namespace" "this" {
  name = var.internal_domain
  vpc  = var.vpc_id
}

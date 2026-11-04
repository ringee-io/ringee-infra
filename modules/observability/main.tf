# Alarms to email through SNS (plan §9). Everything here uses free metrics:
# no Container Insights. A service with no running task stops reporting
# MemoryUtilization, so those alarms treat missing data as breaching: they double
# as "the service is down".

resource "aws_sns_topic" "alarms" {
  name = "${var.name}-alarms"
}

resource "aws_sns_topic_subscription" "email" {
  for_each  = toset(var.alarm_emails)
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = each.value
}

locals {
  actions = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "api_no_healthy_targets" {
  alarm_name          = "${var.name}-api-no-healthy-targets"
  alarm_description   = "No healthy API task behind the ALB."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  dimensions          = { LoadBalancer = var.alb_arn_suffix, TargetGroup = var.api_target_group_arn_suffix }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_actions       = local.actions
  ok_actions          = local.actions
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.name}-alb-target-5xx"
  alarm_description   = "Targets answered more than 20 5xx in 5 minutes."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  dimensions          = { LoadBalancer = var.alb_arn_suffix }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 20
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.actions
}

resource "aws_cloudwatch_metric_alarm" "alb_latency" {
  alarm_name          = "${var.name}-alb-p95-latency"
  alarm_description   = "p95 time to first byte above 3 s for 15 minutes."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  dimensions          = { LoadBalancer = var.alb_arn_suffix }
  extended_statistic  = "p95"
  period              = 300
  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = 3
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.actions
}

resource "aws_cloudwatch_metric_alarm" "service_memory" {
  for_each            = toset(var.ecs_services)
  alarm_name          = "${var.name}-${each.value}-memory-or-down"
  alarm_description   = "${each.value}: memory above 85 % for 15 minutes, or no task running."
  namespace           = "AWS/ECS"
  metric_name         = "MemoryUtilization"
  dimensions          = { ClusterName = var.ecs_cluster_name, ServiceName = each.value }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = 85
  treat_missing_data  = "breaching"
  alarm_actions       = local.actions
  ok_actions          = local.actions
}

resource "aws_cloudwatch_metric_alarm" "rds" {
  for_each = {
    cpu         = { metric = "CPUUtilization", op = "GreaterThanThreshold", threshold = 80, what = "CPU above 80 %" }
    memory      = { metric = "FreeableMemory", op = "LessThanThreshold", threshold = 300 * 1024 * 1024, what = "less than 300 MB of free memory" }
    storage     = { metric = "FreeStorageSpace", op = "LessThanThreshold", threshold = 5 * 1024 * 1024 * 1024, what = "less than 5 GB of free storage" }
    connections = { metric = "DatabaseConnections", op = "GreaterThanThreshold", threshold = 300, what = "more than 300 connections" }
  }
  alarm_name          = "${var.name}-rds-${each.key}"
  alarm_description   = "PostgreSQL: ${each.value.what} for 15 minutes."
  namespace           = "AWS/RDS"
  metric_name         = each.value.metric
  dimensions          = { DBInstanceIdentifier = var.rds_identifier }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  comparison_operator = each.value.op
  threshold           = each.value.threshold
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.actions
}

resource "aws_cloudwatch_metric_alarm" "valkey" {
  for_each = {
    for pair in setproduct(var.valkey_node_ids, ["memory", "evictions", "cpu"]) : "${pair[0]}-${pair[1]}" => {
      node = pair[0]
      kind = pair[1]
    }
  }
  alarm_name          = "${var.name}-valkey-${each.key}"
  alarm_description   = "Valkey ${each.value.node}: ${lookup({ memory = "memory above 80 %", evictions = "more than 100 evictions in 5 minutes", cpu = "engine CPU above 80 %" }, each.value.kind)}."
  namespace           = "AWS/ElastiCache"
  metric_name         = lookup({ memory = "DatabaseMemoryUsagePercentage", evictions = "Evictions", cpu = "EngineCPUUtilization" }, each.value.kind)
  dimensions          = { CacheClusterId = each.value.node }
  statistic           = each.value.kind == "evictions" ? "Sum" : "Average"
  period              = 300
  evaluation_periods  = each.value.kind == "evictions" ? 1 : 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = each.value.kind == "evictions" ? 100 : 80
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.actions
}

# Outside-in check of the public hostname, every minute (plan §9). Route 53
# health check metrics only exist in us-east-1.
resource "aws_route53_health_check" "api" {
  count             = var.health_check_fqdn == null ? 0 : 1
  fqdn              = var.health_check_fqdn
  port              = 443
  type              = "HTTPS"
  resource_path     = "/api/health"
  request_interval  = 30
  failure_threshold = 3
  tags              = { Name = "${var.name}-api-health" }
}

resource "aws_cloudwatch_metric_alarm" "api_health_check" {
  count               = var.health_check_fqdn == null ? 0 : 1
  alarm_name          = "${var.name}-api-health-check"
  alarm_description   = "https://${var.health_check_fqdn}/api/health fails from outside AWS."
  namespace           = "AWS/Route53"
  metric_name         = "HealthCheckStatus"
  dimensions          = { HealthCheckId = aws_route53_health_check.api[0].id }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_actions       = local.actions
  ok_actions          = local.actions
}

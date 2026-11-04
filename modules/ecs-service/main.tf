# One Fargate ARM64 service (or a one-off task definition) with its own log
# group, execution role (reads only its own secrets) and task role.
#
# Who owns the running image:
# - deployed_by_pipeline = true (api, orchestrator, chatgpt-mcp, migrate): the
#   app repo's deploy workflow registers a new revision of this family with the
#   new image and points the service at it. Terraform ignores task_definition
#   on the service, so an apply never rolls a deploy back. A Terraform change to
#   the container (env, secrets, size) creates a revision that the next deploy
#   picks up, because the workflow starts from the family's latest revision.
# - deployed_by_pipeline = false (temporal, temporal-ui): Terraform owns the
#   revision and an apply rolls it out.
#
# Task counts live in the Application Auto Scaling target (min/max), which also
# carries the CPU policy and staging's off-hours schedule, so desired_count on
# the service is only the starting value.

data "aws_region" "current" {}

locals {
  full_name = "${var.name_prefix}-${var.name}"

  # valueFrom is "<secret ARN>:<JSON key>::"; IAM wants the secret ARN alone.
  secret_arns = distinct([
    for value_from in values(var.secrets) :
    regex("^(arn:aws:secretsmanager:[^:]+:[0-9]+:secret:[^:]+)", value_from)[0]
  ])

  container = merge(
    {
      name        = var.name
      image       = var.image
      essential   = true
      stopTimeout = var.stop_timeout
      environment = [for key in sort(keys(var.environment)) : { name = key, value = var.environment[key] }]
      secrets     = [for key in sort(keys(var.secrets)) : { name = key, valueFrom = var.secrets[key] }]
      # Needed for ECS Exec to work reliably.
      linuxParameters = { initProcessEnabled = true }
      portMappings    = var.container_port == null ? [] : [{ containerPort = var.container_port, protocol = "tcp" }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.this.name
          awslogs-region        = data.aws_region.current.region
          awslogs-stream-prefix = var.name
        }
      }
    },
    var.command == null ? {} : { command = var.command },
  )

  service_config = {
    name    = var.name
    cluster = var.cluster_arn
  }
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${local.full_name}"
  retention_in_days = var.log_retention_days
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${local.full_name}-execution"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "execution_secrets" {
  count = length(var.secrets) > 0 ? 1 : 0
  name  = "read-own-secrets"
  role  = aws_iam_role.execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = local.secret_arns
    }]
  })
}

resource "aws_iam_role" "task" {
  name               = "${local.full_name}-task"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

# ECS Exec (shell and port forwarding through SSM; there is no SSH).
resource "aws_iam_role_policy" "task_exec" {
  name = "ecs-exec"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_ecs_task_definition" "this" {
  family                   = local.full_name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn
  container_definitions    = jsonencode([local.container])

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }
}

resource "aws_service_discovery_service" "this" {
  count = var.create_service && var.service_discovery ? 1 : 0
  name  = var.name

  dns_config {
    namespace_id   = var.service_discovery_namespace_id
    routing_policy = "MULTIVALUE"

    dns_records {
      ttl  = 10
      type = "A"
    }
  }

  health_check_custom_config {}
}

resource "aws_ecs_service" "pipeline" {
  count = var.create_service && var.deployed_by_pipeline ? 1 : 0

  name                               = local.service_config.name
  cluster                            = local.service_config.cluster
  task_definition                    = aws_ecs_task_definition.this.arn
  desired_count                      = var.min_capacity
  launch_type                        = "FARGATE"
  platform_version                   = "LATEST"
  enable_execute_command             = true
  propagate_tags                     = "SERVICE"
  deployment_minimum_healthy_percent = var.deployment_minimum_healthy_percent
  deployment_maximum_percent         = var.deployment_maximum_percent
  health_check_grace_period_seconds  = var.load_balanced ? var.health_check_grace_period : null

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = var.security_group_ids
    assign_public_ip = true
  }

  dynamic "load_balancer" {
    for_each = var.load_balanced ? [var.target_group_arn] : []

    content {
      target_group_arn = load_balancer.value
      container_name   = var.name
      container_port   = var.container_port
    }
  }

  dynamic "service_registries" {
    for_each = aws_service_discovery_service.this

    content {
      registry_arn = service_registries.value.arn
    }
  }

  lifecycle {
    ignore_changes = [desired_count, task_definition]
  }
}

resource "aws_ecs_service" "terraform" {
  count = var.create_service && !var.deployed_by_pipeline ? 1 : 0

  name                               = local.service_config.name
  cluster                            = local.service_config.cluster
  task_definition                    = aws_ecs_task_definition.this.arn
  desired_count                      = var.min_capacity
  launch_type                        = "FARGATE"
  platform_version                   = "LATEST"
  enable_execute_command             = true
  propagate_tags                     = "SERVICE"
  deployment_minimum_healthy_percent = var.deployment_minimum_healthy_percent
  deployment_maximum_percent         = var.deployment_maximum_percent
  health_check_grace_period_seconds  = var.load_balanced ? var.health_check_grace_period : null

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = var.security_group_ids
    assign_public_ip = true
  }

  dynamic "load_balancer" {
    for_each = var.load_balanced ? [var.target_group_arn] : []

    content {
      target_group_arn = load_balancer.value
      container_name   = var.name
      container_port   = var.container_port
    }
  }

  dynamic "service_registries" {
    for_each = aws_service_discovery_service.this

    content {
      registry_arn = service_registries.value.arn
    }
  }

  lifecycle {
    ignore_changes = [desired_count]
  }
}

resource "aws_appautoscaling_target" "this" {
  count              = var.create_service ? 1 : 0
  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = "service/${var.cluster_name}/${var.name}"
  min_capacity       = var.min_capacity
  max_capacity       = var.max_capacity

  depends_on = [aws_ecs_service.pipeline, aws_ecs_service.terraform]
}

resource "aws_appautoscaling_policy" "cpu" {
  count              = var.create_service && var.cpu_target != null ? 1 : 0
  name               = "${local.full_name}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.this[0].service_namespace
  resource_id        = aws_appautoscaling_target.this[0].resource_id
  scalable_dimension = aws_appautoscaling_target.this[0].scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = var.cpu_target
    scale_in_cooldown  = 300
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

# Staging runs on weekdays only, 08:00–22:00 in Santo Domingo (plan §4.9).
# RDS starts 15 minutes before the tasks and stops 15 minutes after them.
# Temporal schedules have catch-up windows of minutes, so a cold start does not
# replay a night of missed runs. scripts/staging-power.sh does the same on
# demand.

resource "aws_appautoscaling_scheduled_action" "off" {
  for_each           = var.services
  name               = "${var.name}-${each.key}-off"
  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = each.value.resource_id
  schedule           = "cron(0 ${var.off_hour} ? * MON-FRI *)"
  timezone           = var.timezone

  scalable_target_action {
    min_capacity = 0
    max_capacity = 0
  }
}

resource "aws_appautoscaling_scheduled_action" "on" {
  for_each           = var.services
  name               = "${var.name}-${each.key}-on"
  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = each.value.resource_id
  schedule           = "cron(0 ${var.on_hour} ? * MON-FRI *)"
  timezone           = var.timezone

  scalable_target_action {
    min_capacity = each.value.min
    max_capacity = each.value.max
  }
}

data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${var.name}-rds-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
}

resource "aws_iam_role_policy" "scheduler" {
  name = "start-stop-rds"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["rds:StartDBInstance", "rds:StopDBInstance"]
      Resource = var.rds_instance_arn
    }]
  })
}

resource "aws_scheduler_schedule" "rds_start" {
  name                         = "${var.name}-rds-start"
  schedule_expression          = "cron(45 ${var.on_hour - 1} ? * MON-FRI *)"
  schedule_expression_timezone = var.timezone

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:rds:startDBInstance"
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ DbInstanceIdentifier = var.rds_instance_id })
  }
}

resource "aws_scheduler_schedule" "rds_stop" {
  name                         = "${var.name}-rds-stop"
  schedule_expression          = "cron(15 ${var.off_hour} ? * MON-FRI *)"
  schedule_expression_timezone = var.timezone

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:rds:stopDBInstance"
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ DbInstanceIdentifier = var.rds_instance_id })
  }
}

# terraform test (in modules/stack): applies the whole stack against mocked
# providers, so every expression, for_each key, regex and guard is evaluated
# without AWS credentials. It proves the configuration is coherent, not that
# AWS accepts every value: that is what the staging apply is for.

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-east-1a", "us-east-1b", "us-east-1c"] }
  }

  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }

  mock_data "aws_caller_identity" {
    defaults = { account_id = "111111111111" }
  }

  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }

  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-east-1:111111111111:secret:ringee/test/app-AbCdEf" }
  }

  mock_resource "aws_secretsmanager_secret_version" {
    defaults = { secret_arn = "arn:aws:secretsmanager:us-east-1:111111111111:secret:ringee/test/generated-AbCdEf" }
  }

  mock_resource "aws_db_instance" {
    defaults = {
      address = "ringee-test.abc123.us-east-1.rds.amazonaws.com"
      arn     = "arn:aws:rds:us-east-1:111111111111:db:ringee-test"
      master_user_secret = [{
        secret_arn    = "arn:aws:secretsmanager:us-east-1:111111111111:secret:rds!db-0000-AbCdEf"
        kms_key_id    = "alias/aws/secretsmanager"
        secret_status = "active"
      }]
    }
  }

  mock_resource "aws_elasticache_replication_group" {
    defaults = { primary_endpoint_address = "master.ringee-test.abc123.use1.cache.amazonaws.com" }
  }

  mock_resource "aws_ecr_repository" {
    defaults = { repository_url = "111111111111.dkr.ecr.us-east-1.amazonaws.com/mock" }
  }

  # The provider validates ARNs it receives as inputs, so the mocks that feed
  # other resources need real-looking ones.
  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:us-east-1:111111111111:ringee-test-alarms" }
  }

  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/ringee-test-mock" }
  }

  mock_resource "aws_lb" {
    defaults = {
      arn        = "arn:aws:elasticloadbalancing:us-east-1:111111111111:loadbalancer/app/ringee-test/0123456789abcdef"
      arn_suffix = "app/ringee-test/0123456789abcdef"
    }
  }

  mock_resource "aws_lb_listener" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:111111111111:listener/app/ringee-test/0123456789abcdef/0123456789abcdef" }
  }

  mock_resource "aws_lb_target_group" {
    defaults = {
      arn        = "arn:aws:elasticloadbalancing:us-east-1:111111111111:targetgroup/ringee-test/0123456789abcdef"
      arn_suffix = "targetgroup/ringee-test/0123456789abcdef"
    }
  }

  mock_resource "aws_acm_certificate" {
    defaults = { arn = "arn:aws:acm:us-east-1:111111111111:certificate/00000000-0000-0000-0000-000000000000" }
  }

  mock_resource "aws_ecs_cluster" {
    defaults = { arn = "arn:aws:ecs:us-east-1:111111111111:cluster/ringee-test" }
  }

  mock_resource "aws_ecs_task_definition" {
    defaults = { arn = "arn:aws:ecs:us-east-1:111111111111:task-definition/ringee-test:1" }
  }

  mock_resource "aws_service_discovery_service" {
    defaults = { arn = "arn:aws:servicediscovery:us-east-1:111111111111:service/srv-0123456789abcdef" }
  }
}

mock_provider "random" {
  mock_resource "random_password" {
    defaults = { result = "AbCdEfGh0123456789AbCdEfGh0123456789AbCdEfGh0123456789AbCdEfGh01" }
  }
}

variables {
  env          = "prod"
  cidr         = "10.40.0.0/16"
  api_host     = "api.ringee.io"
  chatgpt_host = "chatgpt.ringee.io"
  running      = true

  api          = { cpu = 512, memory = 2048, min = 2, max = 4 }
  orchestrator = { cpu = 512, memory = 2048, count = 1 }
  temporal     = { cpu = 512, memory = 2048 }
  chatgpt_mcp  = { cpu = 256, memory = 1024, count = 1 }

  rds = {
    instance_class        = "db.t4g.medium"
    multi_az              = true
    allocated_storage     = 30
    max_allocated_storage = 100
    backup_retention_days = 14
    deletion_protection   = true
    skip_final_snapshot   = false
    performance_insights  = true
  }

  valkey = { node_type = "cache.t4g.micro", nodes = 1, engine_version = "8.2" }

  secret_keys = {
    shared        = ["STRIPE_SECRET_KEY", "TELNYX_API_KEY"]
    api           = ["OPENAI_APPS_CHALLENGE_TOKEN"]
    orchestrator  = []
    "chatgpt-mcp" = ["RINGEE_BACKEND_URL"]
  }

  temporal_version             = "1.29.7"
  temporal_admin_tools_version = "1.29.7-tctl-1.18.4-cli-1.7.2"
  temporal_ui_version          = "2.54.1"
  postgres_image_tag           = "17-alpine"

  alb_deletion_protection = true
  alarms                  = true
  alarm_emails            = ["alerts@example.com"]
  health_check_fqdn       = "api.ringee.io"
}

run "prod_tier_b" {
  command = apply

  assert {
    condition     = output.service_scale.api.min == 2 && output.service_scale.temporal.max == 1
    error_message = "Tier B runs two API tasks and exactly one Temporal server."
  }

  assert {
    condition     = length(output.mirror_images) == 4
    error_message = "Every third-party image must be mirrored."
  }

  assert {
    condition     = output.task_families.migrate == "ringee-prod-migrate"
    error_message = "Task families follow ringee-<env>-<name>."
  }
}

run "stopped_until_cutover" {
  command = plan

  variables {
    running = false
  }

  assert {
    condition     = alltrue([for scale in values(output.service_scale) : scale.min == 0 && scale.max == 0])
    error_message = "running = false must keep every service at 0 tasks."
  }
}

run "staging_office_hours" {
  command = apply

  variables {
    env                     = "staging"
    cidr                    = "10.41.0.0/16"
    api_host                = "api.staging.ringee.io"
    chatgpt_host            = "chatgpt.staging.ringee.io"
    api                     = { cpu = 256, memory = 1024, min = 1, max = 2 }
    chatgpt_mcp             = { cpu = 256, memory = 512, count = 0 }
    alb_deletion_protection = false
    alarms                  = false
    office_hours_only       = true
  }
}

run "guard_rejects_managed_variable" {
  command = plan

  variables {
    secret_keys = {
      shared        = ["DATABASE_URL"]
      api           = []
      orchestrator  = []
      "chatgpt-mcp" = []
    }
  }

  expect_failures = [terraform_data.secret_keys_guard]
}

run "guard_rejects_overlapping_scopes" {
  command = plan

  variables {
    secret_keys = {
      shared        = ["STRIPE_SECRET_KEY"]
      api           = ["STRIPE_SECRET_KEY"]
      orchestrator  = []
      "chatgpt-mcp" = []
    }
  }

  expect_failures = [terraform_data.secret_keys_guard]
}

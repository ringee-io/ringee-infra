terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Settings in backend.hcl (see backend.hcl.example): terraform init -backend-config=backend.hcl
  backend "s3" {}
}

provider "aws" {
  region = var.region
  # A wrong AWS_PROFILE fails here instead of touching the other account.
  allowed_account_ids = ["699340623836"]

  default_tags {
    tags = {
      Project   = "ringee"
      Env       = "staging"
      ManagedBy = "terraform"
    }
  }
}

module "stack" {
  source = "../../modules/stack"

  env          = "staging"
  cidr         = "10.41.0.0/16"
  api_host     = "api.staging.ringee.io"
  chatgpt_host = "chatgpt.staging.ringee.io"
  running      = var.running

  # Production's shape at minimum size, for at least 6 months (plan §4.9).
  # api_min_tasks = 2 for the two-task tests of AWS-25.
  api          = { cpu = 256, memory = 1024, min = var.api_min_tasks, max = 2 }
  orchestrator = { cpu = 256, memory = 1024, count = 1 }
  temporal     = { cpu = 256, memory = 2048 }
  chatgpt_mcp  = { cpu = 256, memory = 512, count = 0 }

  rds = {
    instance_class        = "db.t4g.small"
    multi_az              = false
    allocated_storage     = 20
    max_allocated_storage = 50
    backup_retention_days = 3
    deletion_protection   = false
    skip_final_snapshot   = true
    performance_insights  = false
  }

  valkey = { node_type = "cache.t4g.micro", nodes = 1, engine_version = "8.2" }

  secret_keys                  = jsondecode(file("${path.module}/../../config/secret-keys.json"))
  secrets_recovery_window_days = 7

  temporal_version             = var.temporal_version
  temporal_admin_tools_version = var.temporal_admin_tools_version
  temporal_ui_version          = var.temporal_ui_version
  postgres_image_tag           = var.postgres_image_tag

  alb_deletion_protection = false
  alarms                  = false
  office_hours_only       = var.office_hours_only
  log_retention_days      = 14
}

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
  allowed_account_ids = ["405762675020"]

  default_tags {
    tags = {
      Project   = "ringee"
      Env       = "prod"
      ManagedBy = "terraform"
    }
  }
}

module "stack" {
  source = "../../modules/stack"

  env          = "prod"
  cidr         = "10.40.0.0/16"
  api_host     = "api.ringee.io"
  chatgpt_host = "chatgpt.ringee.io"
  # api2.ringee.io reaches this stack before the cutover, while api.ringee.io
  # and chatgpt.ringee.io still point at Railway. The certificate already covers
  # those two, so the cutover only changes DNS.
  api_aliases = ["api2.ringee.io"]
  running     = var.running

  # Tier B, decided 2026-11-04: Multi-AZ database and two API tasks; Valkey
  # with a single node. No read replicas.
  api          = { cpu = 512, memory = 2048, min = var.api_min_tasks, max = 4 }
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

  secret_keys                  = jsondecode(file("${path.module}/../../config/secret-keys.json"))
  secrets_recovery_window_days = 30

  temporal_version             = var.temporal_version
  temporal_admin_tools_version = var.temporal_admin_tools_version
  temporal_ui_version          = var.temporal_ui_version
  postgres_image_tag           = var.postgres_image_tag

  alb_deletion_protection = true
  # With every service at 0 tasks the "service down" alarms would fire for the
  # weeks before the cutover; they appear when the stack is switched on.
  alarms            = var.running
  alarm_emails      = var.alarm_emails
  health_check_fqdn = var.health_check_fqdn
}

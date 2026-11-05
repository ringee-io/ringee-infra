output "alb_dns_name" {
  description = "Target of the api and chatgpt CNAMEs in Cloudflare on cutover night."
  value       = module.alb.dns_name
}

output "certificate_validation_records" {
  value = module.alb.certificate_validation_records
}

output "cluster_name" {
  value = module.cluster.name
}

output "task_subnet_ids" {
  value = module.network.public_subnet_ids
}

output "ops_security_group_id" {
  value = module.security.ids["ops"]
}

output "ecr_urls" {
  value = module.ecr.urls
}

output "rds_address" {
  value = module.rds.address
}

output "rds_identifier" {
  value = module.rds.identifier
}

output "app_secret_arns" {
  value = module.secrets.app_secret_arns
}

output "task_families" {
  description = "Families the deploy workflow and run-task.sh work with."
  value = {
    api            = module.api.task_definition_family
    orchestrator   = module.orchestrator.task_definition_family
    chatgpt-mcp    = module.chatgpt_mcp.task_definition_family
    migrate        = module.migrate.task_definition_family
    db-bootstrap   = module.db_bootstrap.task_definition_family
    temporal-admin = module.temporal_admin.task_definition_family
    ops            = module.ops.task_definition_family
  }
}

output "service_scale" {
  description = "min/max per service while running; staging-power.sh restores these."
  value       = local.scale
}

output "mirror_images" {
  description = "Upstream image => ECR copy (scripts/mirror-images.sh)."
  value = {
    "docker.io/temporalio/server:${var.temporal_version}"                  = local.images.temporal
    "docker.io/temporalio/admin-tools:${var.temporal_admin_tools_version}" = local.images.admin_tools
    "docker.io/temporalio/ui:${var.temporal_ui_version}"                   = local.images.temporal_ui
    "docker.io/library/postgres:${var.postgres_image_tag}"                 = local.images.postgres
  }
}

output "ops_bucket" {
  value = aws_s3_bucket.ops.bucket
}

output "cutover_source_secret" {
  description = "Filled by scripts/prod-data.py with Railway's database URL while it copies the database."
  value       = aws_secretsmanager_secret.cutover_source.name
}

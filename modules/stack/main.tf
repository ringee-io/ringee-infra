# The whole Ringee environment (plan §4). envs/prod and envs/staging call this
# with their own sizes; nothing here knows which one it is beyond var.env.

locals {
  name             = "ringee-${var.env}"
  temporal_address = "temporal.${var.internal_domain}:7233"

  # Variables this stack sets itself. scripts/railway-env.py never copies them
  # and the guard below fails the plan if the key list ever contains one.
  managed_variables = [
    "DATABASE_URL", "REDIS_URL", "REDIS_HOST", "REDIS_PORT", "REDIS_PASSWORD", "REDIS_USERNAME",
    "TEMPORAL_ADDRESS", "PORT", "NODE_ENV", "TRUST_PROXY_HOPS", "RINGEE_MCP_PORT",
  ]

  # A stopped stack (running = false) keeps every service at 0 tasks: the state
  # of plan §10 step 1, before secrets, images and schemas exist.
  scale = {
    api          = var.running ? { min = var.api.min, max = var.api.max } : { min = 0, max = 0 }
    orchestrator = var.running ? { min = var.orchestrator.count, max = var.orchestrator.count } : { min = 0, max = 0 }
    temporal     = var.running ? { min = 1, max = 1 } : { min = 0, max = 0 }
    chatgpt_mcp  = var.running ? { min = var.chatgpt_mcp.count, max = var.chatgpt_mcp.count } : { min = 0, max = 0 }
  }

  images = {
    api          = "${module.ecr.urls["ringee/api"]}:${var.app_image_tag}"
    orchestrator = "${module.ecr.urls["ringee/orchestrator"]}:${var.app_image_tag}"
    chatgpt_mcp  = "${module.ecr.urls["ringee/chatgpt-mcp"]}:${var.app_image_tag}"
    temporal     = "${module.ecr.urls["mirror/temporalio-server"]}:${var.temporal_version}"
    admin_tools  = "${module.ecr.urls["mirror/temporalio-admin-tools"]}:${var.temporal_admin_tools_version}"
    temporal_ui  = "${module.ecr.urls["mirror/temporalio-ui"]}:${var.temporal_ui_version}"
    postgres     = "${module.ecr.urls["mirror/postgres"]}:${var.postgres_image_tag}"
  }
}

# ── Guard: the copied key list must not shadow what Terraform sets ──────────

resource "terraform_data" "secret_keys_guard" {
  lifecycle {
    precondition {
      condition     = length(setintersection(toset(flatten(values(var.secret_keys))), toset(local.managed_variables))) == 0
      error_message = "config/secret-keys.json lists a variable this stack sets itself. Re-run scripts/railway-env.py."
    }

    precondition {
      condition = alltrue([
        length(setintersection(toset(var.secret_keys["shared"]), toset(var.secret_keys["api"]))) == 0,
        length(setintersection(toset(var.secret_keys["shared"]), toset(var.secret_keys["orchestrator"]))) == 0,
      ])
      error_message = "A variable is both shared and service-specific in config/secret-keys.json."
    }
  }
}

# ── Network, registry, data ──────────────────────────────────────────────────

module "network" {
  source = "../network"
  name   = local.name
  cidr   = var.cidr
}

module "security" {
  source = "../security"
  name   = local.name
  vpc_id = module.network.vpc_id
}

module "ecr" {
  source = "../ecr"
  repositories = [
    "ringee/api",
    "ringee/orchestrator",
    "ringee/chatgpt-mcp",
    # Copies of third-party images (scripts/mirror-images.sh): no Docker Hub
    # rate limits at pull time, and a tag can never change under us.
    "mirror/temporalio-server",
    "mirror/temporalio-admin-tools",
    "mirror/temporalio-ui",
    "mirror/postgres",
  ]
}

module "rds" {
  source                = "../rds"
  name                  = local.name
  subnet_ids            = module.network.private_subnet_ids
  security_group_id     = module.security.ids["rds"]
  instance_class        = var.rds.instance_class
  multi_az              = var.rds.multi_az
  allocated_storage     = var.rds.allocated_storage
  max_allocated_storage = var.rds.max_allocated_storage
  backup_retention_days = var.rds.backup_retention_days
  deletion_protection   = var.rds.deletion_protection
  skip_final_snapshot   = var.rds.skip_final_snapshot
  performance_insights  = var.rds.performance_insights
}

module "valkey" {
  source            = "../valkey"
  name              = local.name
  subnet_ids        = module.network.private_subnet_ids
  security_group_id = module.security.ids["valkey"]
  node_type         = var.valkey.node_type
  nodes             = var.valkey.nodes
  engine_version    = var.valkey.engine_version
}

# Application roles. db-bootstrap creates them inside PostgreSQL with these
# passwords; the master user is never used by the apps.
resource "random_password" "db_app" {
  length  = 40
  special = false
}

resource "random_password" "db_temporal" {
  length  = 40
  special = false
}

locals {
  app_db = "postgresql://ringee_app:${random_password.db_app.result}@${module.rds.address}:5432/ringee"
  # Prisma reads connection_limit/pool_timeout; libpq (pg_dump, psql) rejects
  # them, hence PG_URL_APP. Prisma 6's engine encrypts with sslmode=require
  # without verifying the RDS CA.
  prisma_url = { for role, limit in var.connection_limits : role => "${local.app_db}?schema=public&sslmode=require&connection_limit=${limit}&pool_timeout=20" }
}

module "secrets" {
  source               = "../secrets"
  env_name             = var.env
  scopes               = keys(var.secret_keys)
  recovery_window_days = var.secrets_recovery_window_days
  generated = {
    DATABASE_URL_API          = local.prisma_url["api"]
    DATABASE_URL_ORCHESTRATOR = local.prisma_url["orchestrator"]
    DATABASE_URL_MIGRATE      = local.prisma_url["migrate"]
    PG_URL_APP                = "${local.app_db}?sslmode=require"
    APP_DB_PASSWORD           = random_password.db_app.result
    TEMPORAL_DB_PASSWORD      = random_password.db_temporal.result
    REDIS_URL                 = "rediss://:${module.valkey.auth_token}@${module.valkey.primary_endpoint}:6379"
  }
}

locals {
  generated = module.secrets.generated_secret_arn
  master    = module.rds.master_secret_arn

  # scope => { VARIABLE => valueFrom }
  app_secrets = {
    for scope, names in var.secret_keys : scope => {
      for name in names : name => "${module.secrets.app_secret_arns[scope]}:${name}::"
    }
  }
}

# ── Edge and cluster ─────────────────────────────────────────────────────────

module "alb" {
  source              = "../alb"
  name                = local.name
  vpc_id              = module.network.vpc_id
  subnet_ids          = module.network.public_subnet_ids
  security_group_id   = module.security.ids["alb"]
  certificate_domains = concat([var.api_host, var.chatgpt_host], var.api_aliases)
  deletion_protection = var.alb_deletion_protection
  routes = {
    api     = { hosts = concat([var.api_host], var.api_aliases), port = 3000, health_check_path = "/api/health", priority = 10 }
    chatgpt = { hosts = [var.chatgpt_host], port = 4250, health_check_path = "/health", priority = 20 }
  }
}

module "cluster" {
  source          = "../ecs-cluster"
  name            = local.name
  vpc_id          = module.network.vpc_id
  internal_domain = var.internal_domain
}

locals {
  service_defaults = {
    name_prefix  = local.name
    cluster_arn  = module.cluster.arn
    cluster_name = module.cluster.name
    subnet_ids   = module.network.public_subnet_ids
  }
}

# ── Services ─────────────────────────────────────────────────────────────────

module "api" {
  source             = "../ecs-service"
  name               = "api"
  name_prefix        = local.service_defaults.name_prefix
  cluster_arn        = local.service_defaults.cluster_arn
  cluster_name       = local.service_defaults.cluster_name
  subnet_ids         = local.service_defaults.subnet_ids
  security_group_ids = [module.security.ids["api"]]

  image = local.images.api
  # AWS-11: never the image CMD, which runs migrate deploy on every start.
  command        = ["node", "apps/backend/dist/apps/backend/src/main"]
  container_port = 3000
  cpu            = var.api.cpu
  memory         = var.api.memory

  load_balanced    = true
  target_group_arn = module.alb.target_group_arns["api"]
  min_capacity     = local.scale.api.min
  max_capacity     = local.scale.api.max
  cpu_target       = 60
  # AWS-07: the API drains the dialer tick on SIGTERM; the ALB stops sending
  # new requests 30 s before (deregistration delay).
  stop_timeout = 60

  environment = {
    NODE_ENV         = "production"
    PORT             = "3000"
    TRUST_PROXY_HOPS = "1" # AWS-08: one ALB in front.
    TEMPORAL_ADDRESS = local.temporal_address
  }
  secrets = merge(local.app_secrets["shared"], local.app_secrets["api"], {
    DATABASE_URL = "${local.generated}:DATABASE_URL_API::"
    REDIS_URL    = "${local.generated}:REDIS_URL::"
  })

  log_retention_days = var.log_retention_days
}

module "orchestrator" {
  source             = "../ecs-service"
  name               = "orchestrator"
  name_prefix        = local.service_defaults.name_prefix
  cluster_arn        = local.service_defaults.cluster_arn
  cluster_name       = local.service_defaults.cluster_name
  subnet_ids         = local.service_defaults.subnet_ids
  security_group_ids = [module.security.ids["orchestrator"]]

  image   = local.images.orchestrator
  command = ["node", "apps/orchestrator/dist/apps/orchestrator/src/main"]
  cpu     = var.orchestrator.cpu
  memory  = var.orchestrator.memory

  min_capacity = local.scale.orchestrator.min
  max_capacity = local.scale.orchestrator.max
  # The worker drains for 30 s (shutdownGraceTime); two workers on the same
  # task queue coexist during a deploy.
  stop_timeout = 60

  environment = {
    NODE_ENV         = "production"
    TEMPORAL_ADDRESS = local.temporal_address
  }
  secrets = merge(local.app_secrets["shared"], local.app_secrets["orchestrator"], {
    DATABASE_URL = "${local.generated}:DATABASE_URL_ORCHESTRATOR::"
    REDIS_URL    = "${local.generated}:REDIS_URL::"
  })

  log_retention_days = var.log_retention_days
}

module "chatgpt_mcp" {
  source             = "../ecs-service"
  name               = "chatgpt-mcp"
  name_prefix        = local.service_defaults.name_prefix
  cluster_arn        = local.service_defaults.cluster_arn
  cluster_name       = local.service_defaults.cluster_name
  subnet_ids         = local.service_defaults.subnet_ids
  security_group_ids = [module.security.ids["chatgpt"]]

  image          = local.images.chatgpt_mcp
  container_port = 4250
  cpu            = var.chatgpt_mcp.cpu
  memory         = var.chatgpt_mcp.memory

  load_balanced    = true
  target_group_arn = module.alb.target_group_arns["chatgpt"]
  min_capacity     = local.scale.chatgpt_mcp.min
  max_capacity     = local.scale.chatgpt_mcp.max

  environment = {
    NODE_ENV        = "production"
    RINGEE_MCP_PORT = "4250"
  }
  secrets = local.app_secrets["chatgpt-mcp"]

  log_retention_days = var.log_retention_days
}

module "temporal" {
  source             = "../ecs-service"
  name               = "temporal"
  name_prefix        = local.service_defaults.name_prefix
  cluster_arn        = local.service_defaults.cluster_arn
  cluster_name       = local.service_defaults.cluster_name
  subnet_ids         = local.service_defaults.subnet_ids
  security_group_ids = [module.security.ids["temporal"]]

  # temporalio/server, not auto-setup (plan §4.5); the schema comes from the
  # temporal-admin task. Every role runs in this one process, as on Railway,
  # which is why the broadcast address can be loopback. Never more than one
  # task: a second one would need its own IP as the broadcast address.
  image                          = local.images.temporal
  container_port                 = 7233
  cpu                            = var.temporal.cpu
  memory                         = var.temporal.memory
  service_discovery              = true
  service_discovery_namespace_id = module.cluster.namespace_id
  deployed_by_pipeline           = false
  min_capacity                   = local.scale.temporal.min
  max_capacity                   = local.scale.temporal.max
  # Stop the old server before starting the new one: workers retry meanwhile.
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  environment = {
    DB                         = "postgres12"
    DB_PORT                    = "5432"
    POSTGRES_SEEDS             = module.rds.address
    POSTGRES_USER              = "temporal"
    DBNAME                     = "temporal"
    VISIBILITY_DBNAME          = "temporal_visibility"
    SQL_TLS_ENABLED            = "true"
    SQL_HOST_VERIFICATION      = "false"
    SQL_MAX_CONNS              = "10"
    SQL_MAX_IDLE_CONNS         = "10"
    SQL_VIS_MAX_CONNS          = "5"
    SQL_VIS_MAX_IDLE_CONNS     = "5"
    NUM_HISTORY_SHARDS         = "4" # Fixed for the life of the cluster.
    BIND_ON_IP                 = "0.0.0.0"
    TEMPORAL_BROADCAST_ADDRESS = "127.0.0.1"
    LOG_LEVEL                  = "warn"
  }
  secrets = {
    POSTGRES_PWD = "${local.generated}:TEMPORAL_DB_PASSWORD::"
  }

  log_retention_days = 14
}

module "temporal_ui" {
  source             = "../ecs-service"
  name               = "temporal-ui"
  name_prefix        = local.service_defaults.name_prefix
  cluster_arn        = local.service_defaults.cluster_arn
  cluster_name       = local.service_defaults.cluster_name
  subnet_ids         = local.service_defaults.subnet_ids
  security_group_ids = [module.security.ids["temporal_ui"]]

  # No domain, 0 tasks. To debug: scale to 1 and open it through an SSM port
  # forward (README, "Temporal UI").
  image                = local.images.temporal_ui
  container_port       = 8080
  cpu                  = 256
  memory               = 512
  deployed_by_pipeline = false
  min_capacity         = 0
  max_capacity         = 0

  environment = {
    TEMPORAL_ADDRESS           = local.temporal_address
    TEMPORAL_UI_PORT           = "8080"
    TEMPORAL_DEFAULT_NAMESPACE = "default"
  }

  log_retention_days = 7
}

# ── One-off tasks (scripts/run-task.sh) ──────────────────────────────────────

module "migrate" {
  source         = "../ecs-service"
  name           = "migrate"
  name_prefix    = local.name
  create_service = false

  image  = local.images.api
  cpu    = 256
  memory = 512
  command = [
    "node", "packages/database/node_modules/prisma/build/index.js",
    "migrate", "deploy", "--schema", "packages/database/prisma/schema.prisma",
  ]

  environment = { NODE_ENV = "production" }
  secrets     = { DATABASE_URL = "${local.generated}:DATABASE_URL_MIGRATE::" }
}

module "db_bootstrap" {
  source               = "../ecs-service"
  name                 = "db-bootstrap"
  name_prefix          = local.name
  create_service       = false
  deployed_by_pipeline = false

  # Creates the roles and the three databases, and re-applies the passwords
  # from the generated secret. Safe to run again at any time.
  image   = local.images.postgres
  cpu     = 256
  memory  = 512
  command = ["sh", "-c", file("${path.module}/scripts/db-bootstrap.sh")]

  environment = {
    PGHOST     = module.rds.address
    PGPORT     = "5432"
    PGDATABASE = "postgres"
    PGSSLMODE  = "require"
  }
  secrets = {
    PGUSER               = "${local.master}:username::"
    PGPASSWORD           = "${local.master}:password::"
    APP_DB_PASSWORD      = "${local.generated}:APP_DB_PASSWORD::"
    TEMPORAL_DB_PASSWORD = "${local.generated}:TEMPORAL_DB_PASSWORD::"
  }
}

module "temporal_admin" {
  source               = "../ecs-service"
  name                 = "temporal-admin"
  name_prefix          = local.name
  create_service       = false
  deployed_by_pipeline = false

  # Default command: create or upgrade both Temporal schemas (before the server
  # starts). run-task.sh temporal-namespace overrides it to register the
  # "default" namespace once the server is up.
  # The image's ENTRYPOINT is `tini -- sleep infinity`: any command would only
  # be appended to sleep's arguments. Keep tini, drop the sleep.
  image       = local.images.admin_tools
  cpu         = 256
  memory      = 512
  entry_point = ["tini", "--"]
  command     = ["sh", "-c", file("${path.module}/scripts/temporal-schema.sh")]

  environment = {
    SQL_PLUGIN                        = "postgres12"
    SQL_HOST                          = module.rds.address
    SQL_PORT                          = "5432"
    SQL_USER                          = "temporal"
    SQL_TLS                           = "true"
    SQL_TLS_DISABLE_HOST_VERIFICATION = "true"
    TEMPORAL_ADDRESS                  = local.temporal_address
  }
  secrets = {
    SQL_PASSWORD = "${local.generated}:TEMPORAL_DB_PASSWORD::"
  }
}

module "ops" {
  source               = "../ecs-service"
  name                 = "ops"
  name_prefix          = local.name
  create_service       = false
  deployed_by_pipeline = false

  # psql, pg_dump and pg_restore against RDS as the application role. The
  # command always comes from run-task.sh.
  image   = local.images.postgres
  cpu     = 1024
  memory  = 2048
  command = ["sh", "-c", "echo 'pass a command: scripts/run-task.sh ops -- <command>'; exit 2"]

  environment = {
    PGSSLMODE  = "require"
    OPS_BUCKET = aws_s3_bucket.ops.bucket
  }
  secrets = { PG_URL_APP = "${local.generated}:PG_URL_APP::" }

  extra_task_policy = true
  task_policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject"], Resource = "${aws_s3_bucket.ops.arn}/*" },
      { Effect = "Allow", Action = ["s3:ListBucket"], Resource = aws_s3_bucket.ops.arn },
      { Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = aws_secretsmanager_secret.cutover_source.arn },
    ]
  })
}

# Railway's database URL while scripts/prod-data.py copies the database (plan
# §10 step 8). The script writes it right before the dump and overwrites it
# right after; the ops task reads it at run time, so the URL is never in a task
# definition, an override or CloudTrail. Terraform never sets its value.
resource "aws_secretsmanager_secret" "cutover_source" {
  name                    = "ringee/${var.env}/cutover-source"
  description             = "Railway's database URL during a copy by scripts/prod-data.py; a placeholder otherwise."
  recovery_window_in_days = 0
}

# ── Ops bucket ───────────────────────────────────────────────────────────────
# Files the ops task reads or writes: a schema to load, the cutover dump (plan
# §10 step 8). Private, encrypted, TLS only; objects expire after 30 days.

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "ops" {
  bucket = "${local.name}-ops-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "ops" {
  bucket                  = aws_s3_bucket.ops.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "ops" {
  bucket = aws_s3_bucket.ops.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "ops" {
  bucket = aws_s3_bucket.ops.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "ops" {
  bucket = aws_s3_bucket.ops.id

  rule {
    id     = "expire"
    status = "Enabled"
    filter {}

    expiration {
      days = 30
    }
  }
}

resource "aws_s3_bucket_policy" "ops" {
  bucket = aws_s3_bucket.ops.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "TlsOnly"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.ops.arn, "${aws_s3_bucket.ops.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

# ── Alarms (prod) and off-hours schedule (staging) ───────────────────────────

module "observability" {
  count                       = var.alarms ? 1 : 0
  source                      = "../observability"
  name                        = local.name
  alarm_emails                = var.alarm_emails
  alb_arn_suffix              = module.alb.arn_suffix
  api_target_group_arn_suffix = module.alb.target_group_arn_suffixes["api"]
  ecs_cluster_name            = module.cluster.name
  ecs_services                = ["api", "orchestrator", "temporal"]
  rds_identifier              = module.rds.identifier
  valkey_node_ids             = [for i in range(var.valkey.nodes) : format("%s-%03d", local.name, i + 1)]
  health_check_fqdn           = var.health_check_fqdn
}

module "schedule" {
  count            = var.office_hours_only ? 1 : 0
  source           = "../schedule"
  name             = local.name
  rds_instance_id  = module.rds.identifier
  rds_instance_arn = module.rds.arn
  services = {
    api          = { resource_id = module.api.scalable_target_resource_id, min = local.scale.api.min, max = local.scale.api.max }
    orchestrator = { resource_id = module.orchestrator.scalable_target_resource_id, min = local.scale.orchestrator.min, max = local.scale.orchestrator.max }
    temporal     = { resource_id = module.temporal.scalable_target_resource_id, min = local.scale.temporal.min, max = local.scale.temporal.max }
  }
}

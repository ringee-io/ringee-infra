# One coordination budget for the shared Telnyx billing account. This is
# deliberately separate from environment-local application caches.
resource "aws_security_group" "provider_dispatch" {
  name        = "ringee-provider-dispatch"
  description = "Private TLS-only outbound pacing coordination"
  vpc_id      = module.stack.provider_dispatch_network.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "provider_dispatch_local" {
  for_each                     = module.stack.provider_dispatch_network.caller_security_group_ids
  security_group_id            = aws_security_group.provider_dispatch.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
}

# Staging's ECS tasks run in these public subnets. Peering grants no access to
# RDS or the production cache: only this dedicated security group admits them.
resource "aws_vpc_security_group_ingress_rule" "provider_dispatch_staging" {
  security_group_id = aws_security_group.provider_dispatch.id
  cidr_ipv4         = "10.41.0.0/23"
  ip_protocol       = "tcp"
  from_port         = 6379
  to_port           = 6379
}

resource "aws_elasticache_parameter_group" "provider_dispatch" {
  name        = "ringee-provider-dispatch"
  family      = "valkey8"
  description = "Pacing clocks must survive cache pressure"

  parameter {
    name  = "maxmemory-policy"
    value = "noeviction"
  }
}

module "provider_dispatch" {
  source                   = "../../modules/valkey"
  name                     = "ringee-provider-dispatch"
  subnet_ids               = module.stack.provider_dispatch_network.private_subnet_ids
  security_group_id        = aws_security_group.provider_dispatch.id
  node_type                = "cache.t4g.micro"
  nodes                    = 2
  engine_version           = "8.2"
  parameter_group_name     = aws_elasticache_parameter_group.provider_dispatch.name
  snapshot_retention_limit = 7
}

resource "aws_secretsmanager_secret" "provider_dispatch" {
  name                    = "ringee/provider-dispatch"
  description             = "Account-scoped coordination, copied only to the originating services' shared secrets"
  recovery_window_in_days = 30
}

resource "aws_secretsmanager_secret_version" "provider_dispatch" {
  secret_id = aws_secretsmanager_secret.provider_dispatch.id
  secret_string = jsonencode({
    PROVIDER_DISPATCH_REDIS_URL = "rediss://:${module.provider_dispatch.auth_token}@${module.provider_dispatch.primary_endpoint}:6379/0"
  })
}

resource "aws_vpc_peering_connection" "provider_dispatch" {
  vpc_id        = module.stack.provider_dispatch_network.vpc_id
  peer_vpc_id   = "vpc-0f4f7d6e62d92be86"
  peer_owner_id = "699340623836"
  auto_accept   = false
  tags          = { Name = "ringee-provider-dispatch" }
}

output "provider_dispatch_peering_id" {
  description = "Set in staging's provider_dispatch_peering_id to accept this private connection."
  value       = aws_vpc_peering_connection.provider_dispatch.id
}

output "provider_dispatch_secret_arn" {
  description = "Source for the operator's exact-key shared-secret synchronization; never expose its value."
  value       = aws_secretsmanager_secret.provider_dispatch.arn
}

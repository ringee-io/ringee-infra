# The whole access matrix of plan §4.3 in one place.
#
#   internet ──443/80──► alb ──3000──► api
#                            └─4250──► chatgpt
#   api, orchestrator, temporal_ui, ops ──7233──► temporal
#   api, orchestrator, temporal, ops    ──5432──► rds
#   api, orchestrator, ops              ──6379──► valkey
#
# orchestrator, temporal, temporal_ui and ops accept nothing from outside.

locals {
  groups = {
    alb          = "Application Load Balancer"
    api          = "API tasks"
    chatgpt      = "ChatGPT app tasks"
    orchestrator = "Temporal worker tasks"
    temporal     = "Temporal server"
    temporal_ui  = "Temporal UI (no public domain)"
    ops          = "One-off tasks: migrate, db-bootstrap, temporal-admin, ops"
    rds          = "PostgreSQL"
    valkey       = "Valkey"
  }

  ingress = {
    alb_https            = { to = "alb", port = 443, from = null, cidr = "0.0.0.0/0" }
    alb_http             = { to = "alb", port = 80, from = null, cidr = "0.0.0.0/0" }
    api_from_alb         = { to = "api", port = 3000, from = "alb", cidr = null }
    chatgpt_from_alb     = { to = "chatgpt", port = 4250, from = "alb", cidr = null }
    temporal_from_api    = { to = "temporal", port = 7233, from = "api", cidr = null }
    temporal_from_worker = { to = "temporal", port = 7233, from = "orchestrator", cidr = null }
    temporal_from_ui     = { to = "temporal", port = 7233, from = "temporal_ui", cidr = null }
    temporal_from_ops    = { to = "temporal", port = 7233, from = "ops", cidr = null }
    rds_from_api         = { to = "rds", port = 5432, from = "api", cidr = null }
    rds_from_worker      = { to = "rds", port = 5432, from = "orchestrator", cidr = null }
    rds_from_temporal    = { to = "rds", port = 5432, from = "temporal", cidr = null }
    rds_from_ops         = { to = "rds", port = 5432, from = "ops", cidr = null }
    valkey_from_api      = { to = "valkey", port = 6379, from = "api", cidr = null }
    valkey_from_worker   = { to = "valkey", port = 6379, from = "orchestrator", cidr = null }
    valkey_from_ops      = { to = "valkey", port = 6379, from = "ops", cidr = null }
  }

  # Tasks reach ECR, Secrets Manager, CloudWatch, SSM and the providers
  # (Telnyx, Stripe, ...) over the internet: there is no NAT and no endpoint.
  open_egress = ["api", "chatgpt", "orchestrator", "temporal", "temporal_ui", "ops"]
}

resource "aws_security_group" "this" {
  for_each    = local.groups
  name        = "${var.name}-${replace(each.key, "_", "-")}"
  description = each.value
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-${replace(each.key, "_", "-")}" }
}

resource "aws_vpc_security_group_ingress_rule" "this" {
  for_each                     = local.ingress
  security_group_id            = aws_security_group.this[each.value.to].id
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
  cidr_ipv4                    = each.value.cidr
  referenced_security_group_id = each.value.from == null ? null : aws_security_group.this[each.value.from].id
  description                  = each.key
}

resource "aws_vpc_security_group_egress_rule" "alb_to_api" {
  security_group_id            = aws_security_group.this["alb"].id
  ip_protocol                  = "tcp"
  from_port                    = 3000
  to_port                      = 3000
  referenced_security_group_id = aws_security_group.this["api"].id
}

resource "aws_vpc_security_group_egress_rule" "alb_to_chatgpt" {
  security_group_id            = aws_security_group.this["alb"].id
  ip_protocol                  = "tcp"
  from_port                    = 4250
  to_port                      = 4250
  referenced_security_group_id = aws_security_group.this["chatgpt"].id
}

resource "aws_vpc_security_group_egress_rule" "open" {
  for_each          = toset(local.open_egress)
  security_group_id = aws_security_group.this[each.value].id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

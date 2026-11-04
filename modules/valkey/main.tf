# ElastiCache for Valkey, one node by default (decided 2026-11-04). What Redis
# holds is ephemeral: cache, the one-call-at-a-time lease (Postgres is the
# truth behind it), parked webhooks and the realtime fan-out. If the node is
# replaced, ElastiCache brings a new one up within minutes, empty.

resource "random_password" "auth" {
  length  = 64
  special = false
}

resource "aws_elasticache_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.subnet_ids
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = var.name
  description          = "Ringee ${var.name}: cache, dial lease, realtime fan-out"

  engine               = "valkey"
  engine_version       = var.engine_version
  parameter_group_name = var.parameter_group_name
  node_type            = var.node_type
  port                 = 6379

  # Cluster mode stays off: the app uses a single-node client (createClient).
  num_cache_clusters         = var.nodes
  automatic_failover_enabled = var.nodes > 1
  multi_az_enabled           = var.nodes > 1

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [var.security_group_id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                 = random_password.auth.result

  maintenance_window         = "sat:05:00-sat:06:00" # Saturday 01:00–02:00 in Santo Domingo
  snapshot_retention_limit   = 0
  auto_minor_version_upgrade = true
  apply_immediately          = var.apply_immediately
}

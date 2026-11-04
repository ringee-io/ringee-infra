# One PostgreSQL 17 instance holding three databases: ringee, temporal and
# temporal_visibility (plan §4.4). The databases and their owners are created by
# the db-bootstrap task, not here: Terraform cannot reach a private instance.

resource "aws_db_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.subnet_ids
}

resource "aws_db_parameter_group" "this" {
  name   = var.name
  family = "postgres17"

  # RDS reports this parameter as pending-reboot; with the default "immediate"
  # every plan shows an update.
  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }

  # Slow queries only; full statement logging would cost more than it tells.
  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Created here so RDS does not create it with infinite retention.
resource "aws_cloudwatch_log_group" "postgresql" {
  name              = "/aws/rds/instance/${var.name}/postgresql"
  retention_in_days = var.log_retention_days
}

resource "aws_db_instance" "this" {
  identifier     = var.name
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  # B keeps a standby in a second AZ for failover. Nobody reads it, and turning
  # it on or off is an online change (plan §5.1).
  multi_az = var.multi_az

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.security_group_id]
  publicly_accessible    = false
  parameter_group_name   = aws_db_parameter_group.this.name
  port                   = 5432

  # The master user is for the bootstrap task only. RDS keeps (and rotates)
  # its password in Secrets Manager; the apps use their own roles.
  username                    = "ringee_admin"
  manage_master_user_password = true

  backup_retention_period = var.backup_retention_days
  backup_window           = "06:00-06:45"         # 02:00–02:45 in Santo Domingo
  maintenance_window      = "sat:07:00-sat:08:00" # Saturday 03:00–04:00 in Santo Domingo
  copy_tags_to_snapshot   = true

  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.name}-final"

  auto_minor_version_upgrade  = true
  allow_major_version_upgrade = false
  apply_immediately           = var.apply_immediately

  performance_insights_enabled    = var.performance_insights
  enabled_cloudwatch_logs_exports = ["postgresql"]

  depends_on = [aws_cloudwatch_log_group.postgresql]
}

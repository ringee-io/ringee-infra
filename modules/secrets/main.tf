# Two kinds of secret (plan §4.7):
# - ringee/<env>/<scope>: the app variables copied from Railway by
#   scripts/railway-env.py. Terraform creates the container and never writes or
#   reads its value, so Stripe, Telnyx and the rest never touch the state.
# - ringee/<env>/generated: credentials this stack creates (database roles,
#   Valkey token) and the URLs built from them. Its value is in the state, which
#   is why the state bucket is encrypted, versioned and private.
#   ringee/<env>/editor is the same kind, for people instead of apps.

resource "aws_secretsmanager_secret" "app" {
  for_each                = toset(var.scopes)
  name                    = "ringee/${var.env_name}/${each.value}"
  description             = "Copied from Railway by scripts/railway-env.py. Terraform never writes it."
  recovery_window_in_days = var.recovery_window_days
}

resource "aws_secretsmanager_secret" "generated" {
  name                    = "ringee/${var.env_name}/generated"
  description             = "Database roles, Valkey token and the URLs built from them. Managed by Terraform."
  recovery_window_in_days = var.recovery_window_days
}

resource "aws_secretsmanager_secret_version" "generated" {
  secret_id     = aws_secretsmanager_secret.generated.id
  secret_string = jsonencode(var.generated)
}

# The database role that people use (DBeaver through scripts/db-tunnel.sh).
# Kept apart from generated, so that reading it never hands out the apps'
# credentials, and so that creating or changing it never touches the task
# definitions that read generated (Temporal would restart).
resource "aws_secretsmanager_secret" "editor" {
  name                    = "ringee/${var.env_name}/editor"
  description             = "Database role for people (scripts/db-tunnel.sh). Managed by Terraform; no app reads it."
  recovery_window_in_days = var.recovery_window_days
}

resource "aws_secretsmanager_secret_version" "editor" {
  secret_id     = aws_secretsmanager_secret.editor.id
  secret_string = jsonencode(var.editor)
}

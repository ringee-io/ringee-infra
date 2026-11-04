output "app_secret_arns" {
  value = { for scope, secret in aws_secretsmanager_secret.app : scope => secret.arn }
}

output "generated_secret_arn" {
  # Depend on the version so no task definition references an empty secret.
  value = aws_secretsmanager_secret_version.generated.secret_arn
}

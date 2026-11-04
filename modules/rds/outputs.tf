output "address" {
  value = aws_db_instance.this.address
}

output "identifier" {
  value = aws_db_instance.this.identifier
}

output "arn" {
  value = aws_db_instance.this.arn
}

output "master_secret_arn" {
  description = "RDS-managed secret with the master username and password."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

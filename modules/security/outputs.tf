output "ids" {
  description = "Security group id per role: alb, api, chatgpt, orchestrator, temporal, temporal_ui, ops, rds, valkey."
  value       = { for key, group in aws_security_group.this : key => group.id }
}

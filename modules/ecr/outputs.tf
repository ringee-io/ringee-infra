output "urls" {
  description = "Repository URL by name."
  value       = { for name, repo in aws_ecr_repository.this : name => repo.repository_url }
}

output "arns" {
  value = { for name, repo in aws_ecr_repository.this : name => repo.arn }
}

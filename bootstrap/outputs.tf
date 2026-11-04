output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}

output "role_arns" {
  value = { for key, role in aws_iam_role.github : key => role.arn }
}

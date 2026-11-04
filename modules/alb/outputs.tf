output "dns_name" {
  value = aws_lb.this.dns_name
}

output "arn_suffix" {
  value = aws_lb.this.arn_suffix
}

output "target_group_arns" {
  value = { for key, tg in aws_lb_target_group.this : key => tg.arn }
  # ECS refuses a service whose target group no balancer uses yet. The rules
  # wait for the HTTPS listener, which waits for ACM to issue the certificate.
  depends_on = [aws_lb_listener_rule.host]
}

output "target_group_arn_suffixes" {
  value = { for key, tg in aws_lb_target_group.this : key => tg.arn_suffix }
}

output "certificate_validation_records" {
  description = "CNAMEs to create in Cloudflare (DNS only) before the HTTPS listener can exist."
  value = {
    for option in aws_acm_certificate.this.domain_validation_options : option.domain_name => {
      name  = option.resource_record_name
      type  = option.resource_record_type
      value = option.resource_record_value
    }
  }
}

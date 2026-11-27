mock_provider "aws" {
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-east-1:405762675020:secret:ringee/provider-dispatch-AbCdEf" }
  }
}

mock_provider "random" {
  mock_resource "random_password" {
    defaults = { result = "AbCdEfGh0123456789AbCdEfGh0123456789AbCdEfGh0123456789AbCdEfGh01" }
  }
}

override_module {
  target = module.stack
  outputs = {
    provider_dispatch_network = {
      vpc_id             = "vpc-0123456789abcdef0"
      private_subnet_ids = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
      caller_security_group_ids = {
        api          = "sg-0123456789abcdef0"
        orchestrator = "sg-0123456789abcdef1"
        ops          = "sg-0123456789abcdef2"
      }
    }
  }
}

run "shared_private_coordination" {
  command = apply

  assert {
    condition = anytrue([
      for p in aws_elasticache_parameter_group.provider_dispatch.parameter :
      p.name == "maxmemory-policy" && p.value == "noeviction"
    ])
    error_message = "Pacing clocks must not be evicted by application-cache pressure."
  }

  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.provider_dispatch_staging.cidr_ipv4 == "10.41.0.0/23" &&
      aws_vpc_security_group_ingress_rule.provider_dispatch_staging.from_port == 6379 &&
      aws_vpc_security_group_ingress_rule.provider_dispatch_staging.to_port == 6379 &&
      length(aws_vpc_security_group_ingress_rule.provider_dispatch_local) == 3
    )
    error_message = "Only the existing originators, ops, and staging task subnets may reach the private TLS coordinator."
  }

  assert {
    condition     = aws_vpc_peering_connection.provider_dispatch.peer_owner_id == "699340623836" && !aws_vpc_peering_connection.provider_dispatch.auto_accept
    error_message = "The staging account must explicitly accept its own peering connection."
  }
}

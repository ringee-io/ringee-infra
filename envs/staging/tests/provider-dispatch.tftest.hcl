mock_provider "aws" {}
mock_provider "random" {}

override_module {
  target  = module.stack
  outputs = {}
}

run "no_implicit_cross_account_connection" {
  command = plan

  variables {
    provider_dispatch_peering_id = null
  }

  assert {
    condition     = length(aws_vpc_peering_connection_accepter.provider_dispatch) == 0
    error_message = "Staging must not accept an unspecified cross-account connection."
  }
}

run "accept_explicit_coordinator_connection" {
  command = apply

  variables {
    provider_dispatch_peering_id = "pcx-0123456789abcdef0"
  }

  assert {
    condition     = aws_vpc_peering_connection_accepter.provider_dispatch[0].vpc_peering_connection_id == "pcx-0123456789abcdef0" && aws_vpc_peering_connection_accepter.provider_dispatch[0].auto_accept
    error_message = "Staging must accept exactly the production coordinator's peering connection."
  }
}

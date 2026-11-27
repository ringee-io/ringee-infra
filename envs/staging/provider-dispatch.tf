variable "provider_dispatch_peering_id" {
  description = "Production's provider_dispatch_peering_id output. Only the dedicated TLS coordinator is reachable."
  type        = string
  default     = null
}

resource "aws_vpc_peering_connection_accepter" "provider_dispatch" {
  count                     = var.provider_dispatch_peering_id == null ? 0 : 1
  vpc_peering_connection_id = var.provider_dispatch_peering_id
  auto_accept               = true
  tags                      = { Name = "ringee-provider-dispatch" }
}

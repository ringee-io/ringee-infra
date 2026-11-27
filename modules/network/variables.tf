variable "name" {
  type = string
}

variable "cidr" {
  type = string
}

variable "az_count" {
  type    = number
  default = 2
}

variable "peer_routes" {
  description = "Private CIDR => VPC peering connection. Keep routes in the route table's canonical inline owner."
  type        = map(string)
  default     = {}
}

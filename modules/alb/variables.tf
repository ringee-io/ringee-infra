variable "name" {
  description = "At most 32 characters with the longest route key appended."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "security_group_id" {
  type = string
}

variable "certificate_domains" {
  description = "First entry is the certificate's name, the rest are SANs."
  type        = list(string)
}

variable "routes" {
  description = "One target group per route; a route answers on each of its hosts."
  type = map(object({
    hosts             = list(string)
    port              = number
    health_check_path = string
    priority          = number
  }))

  validation {
    # An ALB rule takes at most 5 values per condition.
    condition     = alltrue([for route in values(var.routes) : length(route.hosts) >= 1 && length(route.hosts) <= 5])
    error_message = "Each route needs between 1 and 5 hosts."
  }
}

variable "idle_timeout" {
  description = "Above the dialer SSE heartbeat (15 s) with room for slow clients."
  type        = number
  default     = 120
}

variable "deletion_protection" {
  type = bool
}

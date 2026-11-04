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
  type = map(object({
    host              = string
    port              = number
    health_check_path = string
    priority          = number
  }))
}

variable "idle_timeout" {
  description = "Above the dialer SSE heartbeat (15 s) with room for slow clients."
  type        = number
  default     = 120
}

variable "deletion_protection" {
  type = bool
}

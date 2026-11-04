variable "env" {
  description = "prod or staging."
  type        = string
}

variable "cidr" {
  type = string
}

variable "internal_domain" {
  type    = string
  default = "ringee.internal"
}

variable "api_host" {
  type = string
}

variable "chatgpt_host" {
  type = string
}

variable "running" {
  description = "False keeps every service at 0 tasks (before secrets, images and schemas exist, and until cutover night)."
  type        = bool
}

variable "api" {
  type = object({ cpu = number, memory = number, min = number, max = number })
}

variable "orchestrator" {
  type = object({ cpu = number, memory = number, count = number })
}

variable "temporal" {
  type = object({ cpu = number, memory = number })
}

variable "chatgpt_mcp" {
  type = object({ cpu = number, memory = number, count = number })
}

variable "rds" {
  type = object({
    instance_class        = string
    multi_az              = bool
    allocated_storage     = number
    max_allocated_storage = number
    backup_retention_days = number
    deletion_protection   = bool
    skip_final_snapshot   = bool
    performance_insights  = bool
  })
}

variable "valkey" {
  type = object({ node_type = string, nodes = number, engine_version = string })
}

variable "connection_limits" {
  description = "Prisma pool size per task, by role (plan §4.4)."
  type        = map(number)
  default     = { api = 15, orchestrator = 10, migrate = 2 }
}

variable "secret_keys" {
  description = "Names of the copied app variables per scope (config/secret-keys.json)."
  type        = map(list(string))

  validation {
    condition     = alltrue([for scope in ["shared", "api", "orchestrator", "chatgpt-mcp"] : contains(keys(var.secret_keys), scope)])
    error_message = "secret_keys needs the scopes shared, api, orchestrator and chatgpt-mcp."
  }
}

variable "secrets_recovery_window_days" {
  type    = number
  default = 7
}

variable "app_image_tag" {
  description = "Only the first revision uses it; deploys set the image afterwards."
  type        = string
  default     = "bootstrap"
}

variable "temporal_version" {
  type = string
}

variable "temporal_admin_tools_version" {
  type = string
}

variable "temporal_ui_version" {
  type = string
}

variable "postgres_image_tag" {
  type = string
}

variable "alb_deletion_protection" {
  type = bool
}

variable "alarms" {
  type = bool
}

variable "alarm_emails" {
  type    = list(string)
  default = []
}

variable "health_check_fqdn" {
  type    = string
  default = null
}

variable "office_hours_only" {
  description = "Staging: off at night and on weekends (modules/schedule)."
  type        = bool
  default     = false
}

variable "log_retention_days" {
  type    = number
  default = 30
}

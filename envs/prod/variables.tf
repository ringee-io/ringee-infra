variable "region" {
  description = "Plan §4.1: us-east-1 (same metro as Railway us-east4 and Vercel iad1)."
  type        = string
  default     = "us-east-1"
}

variable "running" {
  description = "False until cutover night (plan §10): infrastructure up, every service at 0 tasks."
  type        = bool
  default     = false
}

variable "api_min_tasks" {
  description = "2 in tier B. Keep 1 until AWS-06 (SSE over Redis) is live."
  type        = number
  default     = 2
}

variable "temporal_version" {
  description = "Same as Railway today. Check the tag exists before mirroring."
  type        = string
  default     = "1.29.7"
}

variable "temporal_admin_tools_version" {
  type    = string
  default = "1.29.7"
}

variable "temporal_ui_version" {
  type    = string
  default = "2.54.1"
}

variable "postgres_image_tag" {
  description = "Client tools for db-bootstrap and ops; same major as RDS."
  type        = string
  default     = "17-alpine"
}

variable "alarm_emails" {
  type    = list(string)
  default = []
}

variable "health_check_fqdn" {
  description = "Set to api.ringee.io after the DNS cutover; before that it would check Railway."
  type        = string
  default     = null
}

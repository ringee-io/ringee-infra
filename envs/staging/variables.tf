variable "region" {
  description = "Plan §4.1: us-east-1 (same metro as Railway us-east4 and Vercel iad1)."
  type        = string
  default     = "us-east-1"
}

variable "running" {
  description = "False until secrets, images and schemas exist."
  type        = bool
  default     = false
}

variable "api_min_tasks" {
  description = "2 for the two-task tests (AWS-25), 1 otherwise."
  type        = number
  default     = 1
}

variable "office_hours_only" {
  description = "Weekdays 08:00-22:00 Santo Domingo; scripts/staging-power.sh overrides it on demand."
  type        = bool
  default     = true
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

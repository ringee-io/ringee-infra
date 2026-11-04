variable "name" {
  type = string
}

variable "alarm_emails" {
  description = "Each address gets a confirmation email from SNS first."
  type        = list(string)
  default     = []
}

variable "alb_arn_suffix" {
  type = string
}

variable "api_target_group_arn_suffix" {
  type = string
}

variable "ecs_cluster_name" {
  type = string
}

variable "ecs_services" {
  description = "Services that must always run (an empty one alarms)."
  type        = list(string)
}

variable "rds_identifier" {
  type = string
}

variable "valkey_node_ids" {
  type = list(string)
}

variable "health_check_fqdn" {
  description = "Null skips the external check (e.g. before the DNS cutover)."
  type        = string
  default     = null
}

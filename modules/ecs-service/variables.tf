variable "name" {
  description = "Service and container name, e.g. api."
  type        = string
}

variable "name_prefix" {
  description = "e.g. ringee-prod; prefixes the family, roles and log group."
  type        = string
}

variable "cluster_arn" {
  type    = string
  default = null
}

variable "cluster_name" {
  type    = string
  default = null
}

variable "image" {
  type = string
}

variable "cpu" {
  type = number
}

variable "memory" {
  type = number
}

variable "command" {
  description = "Overrides the image CMD. Null keeps it."
  type        = list(string)
  default     = null
}

variable "entry_point" {
  description = "Overrides the image ENTRYPOINT, for images whose entrypoint ignores the command. Null keeps it."
  type        = list(string)
  default     = null
}

variable "container_port" {
  type    = number
  default = null
}

variable "environment" {
  description = "Plain variables. Never put a credential here."
  type        = map(string)
  default     = {}
}

variable "secrets" {
  description = "Variable name => Secrets Manager valueFrom (\"<arn>:<KEY>::\")."
  type        = map(string)
  default     = {}
}

variable "subnet_ids" {
  type    = list(string)
  default = []
}

variable "security_group_ids" {
  type    = list(string)
  default = []
}

variable "load_balanced" {
  description = "Register the tasks in target_group_arn. A flag, because the ARN is unknown until apply."
  type        = bool
  default     = false
}

variable "target_group_arn" {
  type    = string
  default = null
}

variable "health_check_grace_period" {
  type    = number
  default = 60
}

variable "service_discovery" {
  description = "Register <name>.<namespace> in Cloud Map. A flag, because the namespace id is unknown until apply."
  type        = bool
  default     = false
}

variable "service_discovery_namespace_id" {
  type    = string
  default = null
}

variable "create_service" {
  description = "False for one-off tasks: only the task definition and roles."
  type        = bool
  default     = true
}

variable "deployed_by_pipeline" {
  type    = bool
  default = true
}

variable "min_capacity" {
  type    = number
  default = 1
}

variable "max_capacity" {
  type    = number
  default = 1
}

variable "cpu_target" {
  description = "Average CPU % to track; null disables CPU scaling."
  type        = number
  default     = null
}

variable "deployment_minimum_healthy_percent" {
  type    = number
  default = 100
}

variable "deployment_maximum_percent" {
  type    = number
  default = 200
}

variable "stop_timeout" {
  description = "Seconds between SIGTERM and SIGKILL (Fargate allows up to 120)."
  type        = number
  default     = 30
}

variable "extra_task_policy" {
  description = "Attach task_policy_json to the task role. A flag, because the JSON is unknown until apply."
  type        = bool
  default     = false
}

variable "task_policy_json" {
  type    = string
  default = null
}

variable "log_retention_days" {
  type    = number
  default = 30
}

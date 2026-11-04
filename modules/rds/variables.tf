variable "name" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "security_group_id" {
  type = string
}

variable "engine_version" {
  description = "Major version; with auto minor upgrades RDS picks the minor."
  type        = string
  default     = "17"
}

variable "instance_class" {
  type = string
}

variable "multi_az" {
  type = bool
}

variable "allocated_storage" {
  type = number
}

variable "max_allocated_storage" {
  type = number
}

variable "backup_retention_days" {
  type = number
}

variable "deletion_protection" {
  type = bool
}

variable "skip_final_snapshot" {
  type = bool
}

variable "performance_insights" {
  type    = bool
  default = true
}

variable "apply_immediately" {
  type    = bool
  default = false
}

variable "log_retention_days" {
  type    = number
  default = 30
}

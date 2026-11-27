variable "name" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "security_group_id" {
  type = string
}

variable "node_type" {
  type    = string
  default = "cache.t4g.micro"
}

variable "nodes" {
  description = "1 = a single node. 2 adds a replica with automatic failover."
  type        = number
  default     = 1
}

variable "engine_version" {
  description = "Confirm with: aws elasticache describe-cache-engine-versions --engine valkey"
  type        = string
  default     = "8.2"
}

variable "parameter_group_name" {
  type    = string
  default = "default.valkey8"
}

variable "apply_immediately" {
  type    = bool
  default = false
}

variable "snapshot_retention_limit" {
  description = "Daily snapshot retention. Application caches default to no snapshots; dispatch coordination retains them."
  type        = number
  default     = 0
}

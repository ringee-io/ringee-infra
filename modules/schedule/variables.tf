variable "name" {
  type = string
}

variable "timezone" {
  type    = string
  default = "America/Santo_Domingo"
}

variable "on_hour" {
  type    = number
  default = 8
}

variable "off_hour" {
  type    = number
  default = 22
}

variable "services" {
  description = "Service key => scalable target resource id and the min/max to restore in the morning."
  type = map(object({
    resource_id = string
    min         = number
    max         = number
  }))
}

variable "rds_instance_id" {
  type = string
}

variable "rds_instance_arn" {
  type = string
}

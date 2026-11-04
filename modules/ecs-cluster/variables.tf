variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "internal_domain" {
  type    = string
  default = "ringee.internal"
}

variable "env_name" {
  type = string
}

variable "scopes" {
  type = list(string)
}

variable "generated" {
  type      = map(string)
  sensitive = true
}

variable "recovery_window_days" {
  type    = number
  default = 7
}

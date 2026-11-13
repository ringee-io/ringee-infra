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

variable "editor" {
  description = "username and password of the database role for people."
  type        = map(string)
  sensitive   = true
}

variable "recovery_window_days" {
  type    = number
  default = 7
}

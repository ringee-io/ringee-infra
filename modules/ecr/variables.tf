variable "repositories" {
  type = list(string)
}

variable "keep_last" {
  type    = number
  default = 30
}

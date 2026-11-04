variable "account_id" {
  description = "The AWS account of this env; the provider refuses any other."
  type        = string
}

variable "env" {
  description = "prod or staging: names the roles' scope and the GitHub environment check."
  type        = string
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "github_org" {
  type    = string
  default = "ringee-io"
}

variable "infra_repo" {
  type    = string
  default = "ringee-infra"
}

variable "app_repo" {
  type    = string
  default = "ringee-app"
}

variable "github_branch" {
  description = "The branch that deploys to this account: main for prod, staging for staging."
  type        = string
}

variable "github_environment" {
  description = "ringee-app environment whose jobs may assume the deploy role."
  type        = string
}

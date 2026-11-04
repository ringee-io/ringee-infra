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

# Immutable GitHub ids that go into the OIDC subject (main.tf, locals). From
# https://api.github.com/repos/ringee-io/<repo>: owner.id and id.
variable "github_org_id" {
  type    = string
  default = "262492135"
}

variable "infra_repo_id" {
  type    = string
  default = "1445215484"
}

variable "app_repo_id" {
  type    = string
  default = "1174124985"
}

variable "github_branch" {
  description = "The branch that deploys to this account: main for prod, staging for staging."
  type        = string
}

variable "github_environment" {
  description = "GitHub environment (same name in ringee-app and ringee-infra) whose jobs may assume the deploy and apply roles."
  type        = string
}

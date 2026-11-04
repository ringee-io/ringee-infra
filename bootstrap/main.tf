# Run once per account (ringee-prod, ringee-staging) with that account's SSO
# profile, in the workspace named after the env. Its state stays local (one per
# workspace, git-ignored) with a copy in the bucket it creates: see README,
# "Bootstrap". Creates:
# - the state bucket (versioned, encrypted, private, TLS only, native locking);
# - GitHub's OIDC provider and three roles, so no AWS key ever lives in GitHub:
#   terraform-plan  ringee-infra pull requests and pushes to <branch>  read-only + state
#   terraform-apply ringee-infra, <env> environment                    administrator
#   deploy          ringee-app, <env> environment                      push to ECR, roll ECS
#   Both repositories are public, which is what lets GitHub Free enforce the
#   environment rules: <env> accepts only <branch>, and production waits for a
#   reviewer (AWS-22). Forks get neither secrets nor OIDC tokens.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region
  # A wrong AWS_PROFILE fails here instead of building prod in staging.
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = {
      Project   = "ringee"
      Env       = var.env
      ManagedBy = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  bucket_name = "ringee-tfstate-${local.account_id}"
  oidc_host   = "token.actions.githubusercontent.com"
}

# ── State bucket ─────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "state" {
  bucket = local.bucket_name

  lifecycle {
    prevent_destroy = true

    precondition {
      condition     = terraform.workspace == var.env
      error_message = "Run in the workspace of this env: terraform workspace select ${var.env}"
    }
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "old-state-versions"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "TlsOnly"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

# ── GitHub OIDC ──────────────────────────────────────────────────────────────

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://${local.oidc_host}"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "trust" {
  for_each = {
    terraform-plan = [
      "repo:${var.github_org}/${var.infra_repo}:pull_request",
      "repo:${var.github_org}/${var.infra_repo}:ref:refs/heads/${var.github_branch}",
    ]
    # GitHub environment names are case-insensitive, and ringee-app already has
    # a "Production" environment (created by Vercel). Which casing reaches the
    # token is not documented, so both are accepted.
    terraform-apply = distinct([
      "repo:${var.github_org}/${var.infra_repo}:environment:${var.github_environment}",
      "repo:${var.github_org}/${var.infra_repo}:environment:${title(var.github_environment)}",
    ])
    deploy = distinct([
      "repo:${var.github_org}/${var.app_repo}:environment:${var.github_environment}",
      "repo:${var.github_org}/${var.app_repo}:environment:${title(var.github_environment)}",
    ])
  }

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = each.value
    }
  }
}

resource "aws_iam_role" "github" {
  for_each             = data.aws_iam_policy_document.trust
  name                 = "github-${each.key}"
  assume_role_policy   = each.value.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "plan_read_only" {
  role       = aws_iam_role.github["terraform-plan"].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# A plan refreshes ringee/<env>/generated and writes the lock file.
resource "aws_iam_role_policy" "plan_state" {
  name = "state-and-generated-secret"
  role = aws_iam_role.github["terraform-plan"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.state.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.state.arn
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = "arn:aws:secretsmanager:${var.region}:${local.account_id}:secret:ringee/${var.env}/generated-*"
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "apply_admin" {
  role       = aws_iam_role.github["terraform-apply"].name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_role_policy" "deploy" {
  name = "push-images-and-roll-services"
  role = aws_iam_role.github["deploy"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:CompleteLayerUpload",
          "ecr:DescribeImages", "ecr:InitiateLayerUpload", "ecr:PutImage", "ecr:UploadLayerPart",
        ]
        Resource = "arn:aws:ecr:${var.region}:${local.account_id}:repository/ringee/*"
      },
      {
        # RegisterTaskDefinition and the Describe calls cannot be scoped.
        Effect = "Allow"
        Action = [
          "ecs:DescribeServices", "ecs:DescribeTaskDefinition", "ecs:DescribeTasks",
          "ecs:ListTasks", "ecs:RegisterTaskDefinition",
        ]
        Resource = "*"
      },
      {
        # run-task needs the subnets and the ops security group; the workflow
        # finds them by name instead of keeping ids in GitHub.
        Effect   = "Allow"
        Action   = ["ec2:DescribeSubnets", "ec2:DescribeSecurityGroups"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ecs:UpdateService"]
        Resource = "arn:aws:ecs:${var.region}:${local.account_id}:service/ringee-${var.env}/*"
      },
      {
        Effect    = "Allow"
        Action    = ["ecs:RunTask"]
        Resource  = "arn:aws:ecs:${var.region}:${local.account_id}:task-definition/ringee-${var.env}-migrate:*"
        Condition = { ArnEquals = { "ecs:cluster" = "arn:aws:ecs:${var.region}:${local.account_id}:cluster/ringee-${var.env}" } }
      },
      {
        Effect    = "Allow"
        Action    = ["iam:PassRole"]
        Resource  = "arn:aws:iam::${local.account_id}:role/ringee-${var.env}-*"
        Condition = { StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" } }
      },
      {
        Effect   = "Allow"
        Action   = ["logs:GetLogEvents", "logs:FilterLogEvents"]
        Resource = "arn:aws:logs:${var.region}:${local.account_id}:log-group:/ecs/ringee-${var.env}-*"
      },
    ]
  })
}

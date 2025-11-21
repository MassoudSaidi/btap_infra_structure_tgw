terraform {
  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }
}

# GitHub Provider
provider "github" {
  token = var.github_token
  owner = var.github_owner
}

locals {
  safe_developer_name = lower(replace(var.developer_name, " ", "-"))
}

# -----------------
# Create GitHub OIDC Provider (if not exists; AWS handles idempotency)
# -----------------
data "aws_iam_openid_connect_provider" "github" {
  count = var.create_iam_resources && !var.create_oidc_provider ? 1 : 0
  url   = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_iam_resources && var.create_oidc_provider ? 1 : 0  # Var to toggle if testing shows existing
  url   = "https://token.actions.githubusercontent.com"

  client_id_list = [
    "sts.amazonaws.com",
  ]
  # Thumbprints omitted per 2025 AWS updates (GitHub now trusted root CA; no longer required)
  # thumbprint_list = [
  #   "6938fd4d98bab03faadb97b34396831e3780aea1",
  #   "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  # ]
}

# -----------------
# Create IAM Role for GitHub Actions (assumable via OIDC)
# -----------------
resource "aws_iam_role" "gha_role" {
  count = var.create_iam_resources ? 1 : 0
  name = "${local.safe_developer_name}-github-actions-deployer-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = {
          Federated = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
        }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_owner}/${var.github_repo}:*"  # Restrict to your repo/branch
          }
        }
      },
    ]
  })
}

# Attach ECS policy (adjust as needed; least privilege ideal)
# resource "aws_iam_role_policy_attachment" "ecs_access" {
#   role       = aws_iam_role.gha_role.name
#   policy_arn = "arn:aws:iam::aws:policy/AmazonECS_FullAccess"
# }

resource "aws_iam_role_policy" "gha_ecs_inline" {
  count = var.create_iam_resources ? 1 : 0
  name   = "${local.safe_developer_name}-gha-ecs-deploy-inline"
  role   = aws_iam_role.gha_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecs:DescribeServices",
          "ecs:DescribeTaskDefinition",
          "ecs:RegisterTaskDefinition",
          "ecs:UpdateService",
          "ecs:DescribeClusters",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage"
        ]
        Resource = "*"
      }
    ]
  })
}

# -----------------
# Push Role ARN to GitHub Secrets (for Actions to assume)
# -----------------
resource "github_actions_secret" "aws_role_arn" {
  count           = var.create_iam_resources ? 1 : 0
  repository      = var.github_repo
  secret_name     = "AWS_ROLE_ARN"
  plaintext_value = aws_iam_role.gha_role.arn
}

resource "github_actions_secret" "aws_region" {
  count           = var.create_iam_resources ? 1 : 0
  repository      = var.github_repo
  secret_name     = "AWS_REGION"
  plaintext_value = var.aws_region
}



# -----------------
# Push Docker Credentials (only if valid)
# -----------------
resource "github_actions_secret" "docker_username" {
  repository      = var.github_repo
  secret_name     = "DOCKER_USERNAME"
  plaintext_value = var.docker_username
  # depends_on      = [null_resource.validate_docker_credentials]
}

resource "github_actions_secret" "docker_password" {
  repository      = var.github_repo
  secret_name     = "DOCKER_PASSWORD"
  plaintext_value = var.docker_password
  # depends_on      = [null_resource.validate_docker_credentials]
}

# -----------------
# Push deployment configuration values that tell GitHub Actions workflow which ECS resources to update.
# ECS Target
# -----------------
resource "github_actions_secret" "ecs_cluster_name" {
  repository      = var.github_repo
  secret_name     = "ECS_CLUSTER_NAME"
  plaintext_value = var.ecs_cluster_name
}

resource "github_actions_secret" "ecs_service_name" {
  repository      = var.github_repo
  secret_name     = "ECS_SERVICE_NAME"
  plaintext_value = var.ecs_service_name
}

resource "github_actions_secret" "ecs_task_family" {
  repository      = var.github_repo
  secret_name     = "ECS_TASK_FAMILY"
  plaintext_value = var.ecs_task_family
}

# -----------------
# Environment variables to ECS Task Definition in the workflow
# Cognito + Redis (per env)
# ---------------------------

# === DEV ===
resource "github_actions_secret" "cognito_region" {
  repository      = var.github_repo
  secret_name     = "COGNITO_REGION"
  plaintext_value = var.cognito_region
}

resource "github_actions_secret" "cognito_user_pool_id" {
  repository      = var.github_repo
  secret_name     = "COGNITO_USER_POOL_ID"
  plaintext_value = var.cognito_user_pool_id
}

resource "github_actions_secret" "cognito_app_client_id" {
  repository      = var.github_repo
  secret_name     = "COGNITO_APP_CLIENT_ID"
  plaintext_value = var.cognito_app_client_id
}

resource "github_actions_secret" "cognito_app_public_client_id" {
  repository      = var.github_repo
  secret_name     = "COGNITO_APP_PUBLIC_CLIENT_ID"
  plaintext_value = var.cognito_app_public_client_id
}

resource "github_actions_secret" "cognito_app_client_secret" {
  repository      = var.github_repo
  secret_name     = "COGNITO_APP_CLIENT_SECRET"
  plaintext_value = var.cognito_app_client_secret
}

resource "github_actions_secret" "cognito_domain" {
  repository      = var.github_repo
  secret_name     = "COGNITO_DOMAIN"
  plaintext_value = var.cognito_domain
}

resource "github_actions_secret" "app_base_url" {
  repository      = var.github_repo
  secret_name     = "APP_BASE_URL"
  plaintext_value = var.app_base_url
}

resource "github_actions_secret" "version_string" {
  repository      = var.github_repo
  secret_name     = "VERSION_STRING"
  plaintext_value = var.version_string
}

resource "github_actions_secret" "redis_endpoint" {
  repository      = var.github_repo
  secret_name     = "REDIS_ENDPOINT"
  plaintext_value = var.redis_endpoint
}

resource "github_actions_secret" "redis_port" {
  repository      = var.github_repo
  secret_name     = "REDIS_PORT"
  plaintext_value = var.redis_port
}

resource "github_actions_secret" "bucket_name" {
  repository      = var.github_repo
  secret_name     = "BUCKET_NAME"
  plaintext_value = var.bucket_name
}


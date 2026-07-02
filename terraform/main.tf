data "aws_caller_identity" "current" {}

locals {
  build_role_name      = "${var.name_prefix}-build-role"
  execution_role_name  = "${var.name_prefix}-execution-role"
  image_name            = "${var.name_prefix}-${var.github_repo}"
  secret_name           = "${var.name_prefix}/${var.github_owner}-${var.github_repo}/github-app"
  base_image_arn        = "arn:aws:lambda:${var.aws_region}:aws:microvm-image:al2023-1"
  log_group_arn_prefix  = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/microvms/${local.image_name}*"
}

# ---------------------------------------------------------------------------
# S3 bucket holding the zipped (Dockerfile + hook_server.py + requirements)
# code artifact that Lambda builds into the MicroVM image.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "runner_artifacts" {
  bucket = "${var.name_prefix}-artifacts-${data.aws_caller_identity.current.account_id}-${var.aws_region}"
}

resource "aws_s3_bucket_versioning" "runner_artifacts" {
  bucket = aws_s3_bucket.runner_artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "runner_artifacts" {
  bucket                  = aws_s3_bucket.runner_artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# IAM: trust policy shared by both MicroVM roles (Lambda assumes these).
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "microvm_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# ---------------------------------------------------------------------------
# IAM: build role - used while Lambda builds the MicroVM image (runs the
# Dockerfile, executes the /ready and /validate hooks).
# ---------------------------------------------------------------------------
resource "aws_iam_role" "microvm_build_role" {
  name               = local.build_role_name
  assume_role_policy = data.aws_iam_policy_document.microvm_assume_role.json
}

data "aws_iam_policy_document" "microvm_build_permissions" {
  statement {
    sid       = "ReadCodeArtifact"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.runner_artifacts.arn}/*"]
  }

  statement {
    sid    = "BuildLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [local.log_group_arn_prefix]
  }
}

resource "aws_iam_role_policy" "microvm_build_role" {
  name   = "${local.build_role_name}-policy"
  role   = aws_iam_role.microvm_build_role.id
  policy = data.aws_iam_policy_document.microvm_build_permissions.json
}

# ---------------------------------------------------------------------------
# IAM: execution role - used at MicroVM runtime (the /run, /resume, /suspend
# and /terminate hooks run under this role). Passed to `run-microvm` as
# --execution-role-arn; it is NOT part of the image resource itself.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "microvm_execution_role" {
  name               = local.execution_role_name
  assume_role_policy = data.aws_iam_policy_document.microvm_assume_role.json
}

data "aws_iam_policy_document" "microvm_execution_permissions" {
  statement {
    sid    = "RuntimeLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [local.log_group_arn_prefix]
  }

  statement {
    sid       = "ReadGithubAppSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.github_app.arn]
  }

  statement {
    # Lets the runner terminate its own MicroVM once the job finishes, so
    # ephemeral runners never sit around accruing charges.
    # See runner-image/hook_server.py -> _self_terminate().
    sid       = "SelfTerminate"
    effect    = "Allow"
    actions   = ["lambda:TerminateMicrovm", "lambda:GetMicrovm"]
    resources = ["arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:microvm:*"]
  }
}

resource "aws_iam_role_policy" "microvm_execution_role" {
  name   = "${local.execution_role_name}-policy"
  role   = aws_iam_role.microvm_execution_role.id
  policy = data.aws_iam_policy_document.microvm_execution_permissions.json
}

# ---------------------------------------------------------------------------
# Secrets Manager: GitHub App credentials used to mint fresh, ~1h runner
# registration tokens on every MicroVM launch (see runner-image/hook_server.py).
#
# Expected JSON shape:
#   {"app_id": "...", "installation_id": "...", "private_key": "-----BEGIN RSA PRIVATE KEY-----..."}
#
# The real value is populated out-of-band (see ../README.md) via
# `aws secretsmanager put-secret-value` rather than through Terraform, so the
# private key never ends up in a .tf file or in state as a diffable value.
# ---------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "github_app" {
  name        = local.secret_name
  description = "GitHub App credentials for ${var.github_owner}/${var.github_repo} ephemeral MicroVM runner"
}

resource "aws_secretsmanager_secret_version" "github_app" {
  secret_id = aws_secretsmanager_secret.github_app.id
  secret_string = jsonencode({
    app_id          = "REPLACE_ME"
    installation_id = "REPLACE_ME"
    private_key     = "REPLACE_ME"
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ---------------------------------------------------------------------------
# MicroVM image.
#
# IMPORTANT - apply this in two passes (see ../README.md):
#   1. Everything above (bucket, IAM, secret container) first.
#   2. Build the image on the EC2 box, zip it, upload it to
#      s3://<bucket>/gh-runner-image.zip - THEN apply this resource, since
#      Lambda fetches the artifact at create time and the object must exist.
#
# NOTE (2026-07): Lambda MicroVMs shipped 2026-06-22; the awscc provider added
# awscc_lambda_microvm_image in 1.89.0 just days before that. The generated
# provider schema currently lists nearly every property as "Required" -
# including some (e.g. base_image_version, hooks, logging) that the
# equivalent `create-microvm-image` CLI call treats as optional. That looks
# like the schema generator mirroring the full CloudFormation property list
# rather than true create-time requirements. The values below are a
# best-effort, minimal-but-valid configuration - if `terraform apply` rejects
# one of them, the error message is the most reliable source of truth; adjust
# accordingly (this file has not been run through `terraform validate` in a
# live environment as of writing).
# ---------------------------------------------------------------------------
resource "awscc_lambda_microvm_image" "gh_runner" {
  name        = local.image_name
  description = "Ephemeral GitHub Actions self-hosted runner for ${var.github_owner}/${var.github_repo}"

  code_artifact = {
    uri = "s3://${aws_s3_bucket.runner_artifacts.bucket}/gh-runner-image.zip"
  }

  base_image_arn     = local.base_image_arn
  base_image_version = "" # latest - see note above if this is rejected
  build_role_arn     = aws_iam_role.microvm_build_role.arn

  cpu_configurations = [
    { architecture = "arm64" } # Lambda MicroVMs only supports ARM64 today
  ]

  resources = [
    { minimum_memory_in_mi_b = var.runner_image_baseline_memory_mib }
  ]

  additional_os_capabilities = []
  egress_network_connectors  = [] # build-time egress: default public internet

  environment_variables = [
    { key = "GITHUB_OWNER", value = var.github_owner },
    { key = "GITHUB_REPO", value = var.github_repo },
    { key = "GH_APP_SECRET_ARN", value = aws_secretsmanager_secret.github_app.arn },
    { key = "RUNNER_LABELS", value = var.runner_labels },
    { key = "HOOK_PORT", value = "8080" },
  ]

  hooks = {
    port = 8080
  }

  logging = {}

  tags = [
    { key = "Project", value = var.name_prefix }
  ]

  depends_on = [
    aws_iam_role_policy.microvm_build_role,
    aws_iam_role_policy.microvm_execution_role,
  ]
}

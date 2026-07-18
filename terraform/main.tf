data "aws_caller_identity" "current" {}

locals {
  build_role_name     = "${var.name_prefix}-build-role"
  execution_role_name = "${var.name_prefix}-execution-role"
  # The generation segment enables blue/green image rollovers: bumping
  # var.image_generation gives the replacement image a fresh name so it can
  # coexist with the previous one during burn-in (MIGRATION_PLAN.md, Phase 3/4).
  image_name     = "${var.name_prefix}-${var.github_repo}-${var.image_generation}"
  secret_name    = coalesce(var.github_app_secret_name, "${var.name_prefix}/${var.github_owner}-${var.github_repo}/github-app")
  base_image_arn = "arn:aws:lambda:${var.aws_region}:aws:microvm-image:al2023-1"

  # CONFIRMED (2026-07) via a console-generated default build role: the real
  # log group path is /aws/lambda-microvms/<name> (one hyphenated segment),
  # NOT /aws/lambda/microvms/<name> as AWS's own prose docs state (blog post
  # + developer guide both say the latter - this looks like a documentation
  # bug). Getting this wrong means the build role can't create its log
  # group/stream at all, which - since even the failure would need to be
  # logged - looks like the build never started (no log stream whatsoever),
  # not like a permissions error. If AWS fixes the docs/path back to match
  # the prose, this is the line to revert.
  log_group_arn_prefix = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda-microvms/${local.image_name}*"
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
    #
    # CONFIRMED (2026-07-10) via a live AccessDenied: TerminateMicrovm is
    # authorized against the *microvm-image* ARN the MicroVM was launched
    # from, not against a microvm:* instance ARN as we first assumed. Scoping
    # to this stack's image is tighter than the old microvm:* wildcard anyway:
    # a runner can only terminate MicroVMs of its own image. The microvm:*
    # pattern is kept in case other operations (e.g. GetMicrovm) authorize
    # against the instance ARN instead - same unknown, other direction.
    sid     = "SelfTerminate"
    effect  = "Allow"
    actions = ["lambda:TerminateMicrovm", "lambda:GetMicrovm"]
    resources = [
      "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:microvm-image:${local.image_name}",
      "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:microvm:*",
    ]
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
# MicroVM image - managed through CloudFormation instead of the awscc
# provider because of two confirmed awscc defects (empty-Set(String)
# serialization dropping [] from requests + a read handler that returns null
# for every property except name/arn/tags, forcing ignore_changes on
# everything). Full rationale, phases and rollback: ../MIGRATION_PLAN.md.
#
# The template is static (no interpolation); all inputs enter as CFN
# Parameters, so the reviewed YAML is byte-identical to what is deployed.
#
# Rolling a new image = bumping var.image_generation: the Name change is a
# CFN *replacement* (new image built, old deleted in the cleanup step), never
# an in-place UpdateMicrovmImage - deliberate, given community reports of
# in-place updates losing hooks/os-capabilities.
# ---------------------------------------------------------------------------
resource "aws_cloudformation_stack" "microvm_image" {
  name          = "${var.name_prefix}-microvm-image"
  template_body = file("${path.module}/templates/microvm-image.yaml")

  parameters = {
    ImageName         = local.image_name
    ImageDescription  = "Ephemeral GitHub Actions self-hosted runner for ${var.github_owner}/${var.github_repo}"
    CodeArtifactUri   = "s3://${aws_s3_bucket.runner_artifacts.bucket}/gh-runner-image.zip"
    BaseImageArn      = local.base_image_arn
    BaseImageVersion  = var.base_image_version
    BuildRoleArn      = aws_iam_role.microvm_build_role.arn
    BaselineMemoryMiB = var.runner_image_baseline_memory_mib
    GithubOwner       = var.github_owner
    GithubRepo        = var.github_repo
    GhAppSecretArn    = aws_secretsmanager_secret.github_app.arn
    RunnerLabels      = var.runner_labels
    MicrovmAwsRegion  = var.aws_region
    ProjectTag        = var.name_prefix
  }

  # Failed create/update rolls back automatically - no half-applied images.
  on_failure = "ROLLBACK"

  # Stack policy: the image may be replaced (blue/green via
  # var.image_generation) but never silently deleted by a routine update.
  policy_body = jsonencode({
    Statement = [
      {
        Effect    = "Allow"
        Action    = "Update:*"
        Principal = "*"
        Resource  = "*"
      },
      {
        Effect    = "Deny"
        Action    = "Update:Delete"
        Principal = "*"
        Resource  = "LogicalResourceId/MicrovmImage"
      },
    ]
  })

  tags = {
    Project = var.name_prefix
  }

  depends_on = [
    aws_iam_role_policy.microvm_build_role,
    aws_iam_role_policy.microvm_execution_role,
  ]
}

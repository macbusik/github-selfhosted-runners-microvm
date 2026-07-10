data "aws_caller_identity" "current" {}

locals {
  build_role_name     = "${var.name_prefix}-build-role"
  execution_role_name = "${var.name_prefix}-execution-role"
  image_name          = "${var.name_prefix}-${var.github_repo}"
  secret_name         = coalesce(var.github_app_secret_name, "${var.name_prefix}/${var.github_owner}-${var.github_repo}/github-app")
  base_image_arn      = "arn:aws:lambda:${var.aws_region}:aws:microvm-image:al2023-1"

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
    sid    = "SelfTerminate"
    effect = "Allow"
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
# MicroVM image.
#
# NOT created by `terraform apply` - see ../README.md "Faza 2 - obraz
# MicroVM". Reason: awscc_lambda_microvm_image has a confirmed provider bug
# (2026-07, same class as https://github.com/hashicorp/terraform-provider-awscc/issues/847)
# where empty Set(String) attributes (additional_os_capabilities,
# egress_network_connectors) are dropped from the CreateResource request
# entirely instead of being sent as `[]`, and Cloud Control then rejects the
# call with "required key not found". additional_os_capabilities has no
# non-empty value we actually want (the only option is ["ALL"], i.e. elevated
# OS capabilities we don't need for a runner that just does `git clone` +
# build tooling) - so instead of enabling that, this resource is:
#   1. Created out-of-band with `aws lambda-microvms create-microvm-image`
#      (the CLI correctly omits untouched optional fields - no bug there).
#   2. Pulled into this state with `terraform import
#      awscc_lambda_microvm_image.gh_runner <image-arn>` so future changes
#      (e.g. a new code_artifact version) are still Terraform-tracked.
# `lifecycle.ignore_changes` below keeps Terraform from ever trying to
# "correct" additional_os_capabilities/egress_network_connectors back to the
# empty values in this HCL - an UpdateResource call would hit the identical
# bug. If a later awscc release fixes this, drop the ignore_changes and the
# import step and just `terraform apply` normally.
#
# Also confirmed by the same debugging session:
#   - base_image_version cannot be an empty string - it must be an actual
#     version identifier of the al2023-1 base image, looked up via
#     `aws lambda-microvms list-managed-microvm-image-versions`.
#   - cpu_configurations.architecture must be the enum value "ARM_64", not
#     the CLI-style lowercase "arm64".
# ---------------------------------------------------------------------------
resource "awscc_lambda_microvm_image" "gh_runner" {
  name        = local.image_name
  description = "Ephemeral GitHub Actions self-hosted runner for ${var.github_owner}/${var.github_repo}"

  code_artifact = {
    uri = "s3://${aws_s3_bucket.runner_artifacts.bucket}/gh-runner-image.zip"
  }

  base_image_arn     = local.base_image_arn
  base_image_version = var.base_image_version
  build_role_arn     = aws_iam_role.microvm_build_role.arn

  cpu_configurations = [
    { architecture = "ARM_64" } # Lambda MicroVMs only supports ARM64 today
  ]

  resources = [
    { minimum_memory_in_mi_b = var.runner_image_baseline_memory_mib }
  ]

  # Placeholder values only - see the resource-level comment above. The real
  # values come from whatever the CLI `create-microvm-image` call defaults to
  # (recommendation: don't pass --additional-os-capabilities or
  # --egress-network-connectors at all, matching AWS's own getting-started
  # tutorial) and are then locked in via `terraform import` + ignore_changes.
  additional_os_capabilities = []
  egress_network_connectors  = []

  environment_variables = [
    { key = "GITHUB_OWNER", value = var.github_owner },
    { key = "GITHUB_REPO", value = var.github_repo },
    { key = "GH_APP_SECRET_ARN", value = aws_secretsmanager_secret.github_app.arn },
    { key = "RUNNER_LABELS", value = var.runner_labels },
    { key = "HOOK_PORT", value = "8080" },
    # Region churn: on 2026-07-06 MicroVMs did NOT auto-inject AWS_REGION
    # (boto3 NoRegionError without it), but as of 2026-07-09 the
    # CreateMicrovmImage API rejects AWS_REGION as a *reserved* env var key -
    # implying the platform now injects it. hook_server.py prefers the
    # platform's AWS_REGION and falls back to this variable, so we stay
    # correct either way. Must match var.aws_region / where this image runs.
    { key = "MICROVM_AWS_REGION", value = var.aws_region },
  ]

  # CONFIRMED (2026-07-09) via CLI: the API rejects a hooks config that only
  # sets the port - "At least one MicroVM hook or MicroVM image hook must be
  # enabled when the hooks port is specified". These four are exactly what
  # hook_server.py implements; resume/suspend stay unset (this image is never
  # run with an idle policy - ephemeral runners terminate, they don't sleep).
  hooks = {
    port = 8080
    microvm_image_hooks = {
      ready    = "ENABLED"
      validate = "ENABLED"
    }
    microvm_hooks = {
      run = "ENABLED"
      # /run does real work before answering: Secrets Manager + two GitHub
      # API calls + config.sh (runner registration, ~10-20s alone). The
      # default run-hook timeout is undocumented, and CONFIRMED (2026-07-10):
      # the API caps runTimeoutInSeconds at 60 - so 60 it is. If registration
      # ever exceeds that, /run has to respond 200 earlier and finish
      # registration in the background (weaker failure semantics).
      run_timeout_in_seconds = 60
      terminate              = "ENABLED"
    }
  }

  logging = {}

  tags = [
    { key = "Project", value = var.name_prefix }
  ]

  depends_on = [
    aws_iam_role_policy.microvm_build_role,
    aws_iam_role_policy.microvm_execution_role,
  ]

  lifecycle {
    # Two separate provider/service gaps force this list (both confirmed live):
    #
    # 1. additional_os_capabilities / egress_network_connectors: empty
    #    Set(String) values are dropped from the CreateResource/UpdateResource
    #    request instead of being sent as [], and Cloud Control rejects that
    #    with "required key not found" (still present in awscc 1.92.0).
    #
    # 2. Everything else below: as of 2026-07-09 the Cloud Control *read*
    #    handler for this brand-new resource returns only name/ARN/tags -
    #    every other property comes back null even though the
    #    create-microvm-image response confirms they are set server-side.
    #    Without ignoring them, terraform plan forever wants to "add" values
    #    that are already there, and applying that would call
    #    UpdateMicrovmImage (= new image version, with community reports of
    #    updates losing hooks/os-capabilities).
    #
    # Consequence: changing e.g. code_artifact or environment_variables in
    # this file does NOT roll a new image - rebuild via the CLI flow in
    # ../README.md (Faza 2) and re-import. Revisit this list whenever
    # `terraform plan` after an `init -upgrade` starts showing real values
    # being read back instead of nulls.
    ignore_changes = [
      additional_os_capabilities,
      egress_network_connectors,
      base_image_arn,
      base_image_version,
      build_role_arn,
      code_artifact,
      cpu_configurations,
      description,
      environment_variables,
      hooks,
      logging,
      resources,
    ]
  }
}

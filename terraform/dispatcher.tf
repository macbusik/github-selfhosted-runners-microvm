# ---------------------------------------------------------------------------
# Dispatcher: GitHub `workflow_job` webhook -> run-microvm.
#
# Lambda + Function URL (auth NONE) zamiast API Gateway - jedyna realna
# autoryzacja webhooka GitHuba to HMAC podpisu (X-Hub-Signature-256),
# weryfikowany w kodzie (dispatcher/handler.py). API Gateway nie dodalby tu
# zadnej warstwy autoryzacji (GitHub nie podpisuje SigV4), a dodalby koszt
# i zasoby. Function URL + weryfikacja HMAC to wzorzec rekomendowany przez
# sam GitHub dla webhook receiverow.
#
# Paczka: dispatcher/dispatcher.zip budowana OUT-OF-BAND przez
# dispatcher/build.sh (ten sam wzorzec co artefakt obrazu runnera).
# Powod bundlowania boto3: runtime'owy boto3 Lambdy potrafi nie znac
# lambda-microvms (lekcja z runner-image: UnknownServiceError dopiero przy
# pierwszym uzyciu) - build.sh asertuje model uslugi w czasie builda.
# ---------------------------------------------------------------------------

locals {
  dispatcher_name     = "${var.name_prefix}-dispatcher"
  dispatcher_zip      = "${path.module}/../dispatcher/dispatcher.zip"
  webhook_secret_name = "${var.name_prefix}/${var.github_owner}-${var.github_repo}/webhook"
}

# ---------------------------------------------------------------------------
# Secrets Manager: sekret HMAC webhooka. Placeholder + ignore_changes -
# prawdziwa wartosc wchodzi out-of-band (patrz ../README.md, sekcja
# "Dispatcher"), zeby nigdy nie wyladowala w .tf ani w state jako diff.
# Ten sam wzorzec co sekret GitHub App w main.tf.
# ---------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "webhook" {
  name        = local.webhook_secret_name
  description = "HMAC secret for the ${var.github_owner}/${var.github_repo} workflow_job webhook (dispatcher)"
}

resource "aws_secretsmanager_secret_version" "webhook" {
  secret_id     = aws_secretsmanager_secret.webhook.id
  secret_string = "REPLACE_ME"

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ---------------------------------------------------------------------------
# IAM: rola dispatchera - logi, odczyt sekretu webhooka, RunMicrovm na
# obrazie tego stacku i PassRole na execution role (run-microvm przekazuje
# ja MicroVM-owi).
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "dispatcher_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dispatcher" {
  name               = "${local.dispatcher_name}-role"
  assume_role_policy = data.aws_iam_policy_document.dispatcher_assume_role.json
}

data "aws_iam_policy_document" "dispatcher_permissions" {
  statement {
    sid    = "Logs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.dispatcher_name}*"]
  }

  statement {
    sid       = "ReadWebhookSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.webhook.arn]
  }

  statement {
    # Ta sama niepewnosc co przy SelfTerminate w main.tf: TerminateMicrovm
    # autoryzuje sie wzgledem ARN-a OBRAZU (potwierdzone na zywo 2026-07-10),
    # wiec dla RunMicrovm zakladamy to samo i na wszelki wypadek dokladamy
    # microvm:* - do zawezenia, gdy AWS udokumentuje resource types.
    sid     = "RunMicrovm"
    effect  = "Allow"
    actions = ["lambda:RunMicrovm"]
    resources = [
      "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:microvm-image:${local.image_name}",
      "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:microvm:*",
    ]
  }

  statement {
    # CONFIRMED (2026-07-10) kolejna nieudokumentowana akcja: RunMicrovm
    # autoryzuje lambda:PassNetworkConnector na DOMYSLNYCH konektorach
    # (HTTP_INGRESS/INTERNET_EGRESS), nawet gdy request zadnych nie podaje.
    # Zawezone do konektorow zarzadzanych przez AWS (konto "aws" w ARN) -
    # NIE obejmuje ewentualnych wlasnych konektorow VPC-egress; jesli kiedys
    # dojdzie aws_lambda_network_connector, trzeba tu dodac jego ARN.
    sid       = "PassManagedNetworkConnectors"
    effect    = "Allow"
    actions   = ["lambda:PassNetworkConnector"]
    resources = ["arn:aws:lambda:${var.aws_region}:aws:network-connector:aws-network-connector:*"]
  }

  statement {
    # run-microvm z --execution-role-arn wymaga iam:PassRole na te role.
    #
    # CELOWO BEZ condition na iam:PassedToService: proba zawezenia do
    # lambda.amazonaws.com konczyla sie AccessDenied (potwierdzone na zywo
    # 2026-07-10) - kontekst autoryzacji RunMicrovm najwyrazniej nie niesie
    # tej wartosci (ta sama klasa niespodzianek co autoryzacja Terminate
    # wzgledem ARN-a obrazu). Brak warunku kompensuje trust policy samej
    # execution role: przejac ja moze wylacznie lambda.amazonaws.com, wiec
    # "przekazanie gdzie indziej" i tak jest niewykonalne. Do ponownego
    # zawezenia, gdy AWS udokumentuje wartosc PassedToService dla MicroVMs.
    sid       = "PassExecutionRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.microvm_execution_role.arn]
  }
}

resource "aws_iam_role_policy" "dispatcher" {
  name   = "${local.dispatcher_name}-policy"
  role   = aws_iam_role.dispatcher.id
  policy = data.aws_iam_policy_document.dispatcher_permissions.json
}

# ---------------------------------------------------------------------------
# Funkcja + publiczny Function URL.
# ---------------------------------------------------------------------------
resource "aws_lambda_function" "dispatcher" {
  function_name = local.dispatcher_name
  description   = "workflow_job webhook -> run-microvm dla ${var.github_owner}/${var.github_repo}"
  role          = aws_iam_role.dispatcher.arn

  filename         = local.dispatcher_zip
  source_code_hash = filebase64sha256(local.dispatcher_zip)
  handler          = "handler.handler"
  runtime          = "python3.13"
  architectures    = ["arm64"]
  timeout          = 30
  memory_size      = 256

  environment {
    variables = {
      WEBHOOK_SECRET_ARN           = aws_secretsmanager_secret.webhook.arn
      MICROVM_IMAGE_ARN            = aws_cloudformation_stack.microvm_image.outputs["ImageArn"]
      MICROVM_EXECUTION_ROLE_ARN   = aws_iam_role.microvm_execution_role.arn
      MICROVM_MAX_DURATION_SECONDS = tostring(var.dispatcher_max_duration_seconds)
      ALLOWED_REPO                 = "${var.github_owner}/${var.github_repo}"
      RUNNER_LABELS                = var.runner_labels
    }
  }

  depends_on = [aws_iam_role_policy.dispatcher]
}

resource "aws_lambda_function_url" "dispatcher" {
  function_name      = aws_lambda_function.dispatcher.function_name
  authorization_type = "NONE" # autoryzacja = HMAC webhooka, patrz komentarz na gorze
}

resource "aws_lambda_permission" "dispatcher_public_url" {
  statement_id           = "AllowPublicFunctionUrl"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.dispatcher.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

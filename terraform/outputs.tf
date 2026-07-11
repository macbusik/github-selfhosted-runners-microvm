output "microvm_image_arn" {
  description = "ARN of the MicroVM image - pass as --image-identifier to run-microvm."
  value       = awscc_lambda_microvm_image.gh_runner.image_arn
}

output "build_role_arn" {
  value = aws_iam_role.microvm_build_role.arn
}

output "execution_role_arn" {
  description = "Pass as --execution-role-arn to `run-microvm`. Not part of the image resource - execution roles are supplied per-MicroVM at run time."
  value       = aws_iam_role.microvm_execution_role.arn
}

output "github_app_secret_arn" {
  description = "Populate with the real GitHub App credentials via `aws secretsmanager put-secret-value` - see ../README.md."
  value       = aws_secretsmanager_secret.github_app.arn
}

output "artifact_bucket" {
  value = aws_s3_bucket.runner_artifacts.bucket
}

output "dispatcher_webhook_url" {
  description = "Payload URL webhooka GitHub (workflow_job, content type application/json). Chroniony HMAC-iem - patrz dispatcher_webhook_secret_arn."
  value       = aws_lambda_function_url.dispatcher.function_url
}

output "dispatcher_webhook_secret_arn" {
  description = "Uzupelnij TA SAMA wartoscia, ktora podasz jako secret webhooka w GitHub - patrz ../README.md, sekcja Dispatcher."
  value       = aws_secretsmanager_secret.webhook.arn
}

output "run_microvm_example_command" {
  # CONFIRMED (2026-07-10): passing the NO_INGRESS connector ARN makes
  # RunMicrovm fail with 403 "Unable to determine service/operation name to
  # be authorized" (service-side auth-mapping bug - the same call without
  # --ingress-network-connectors succeeds). Until AWS fixes it we omit the
  # flag and accept the default HTTP_INGRESS: the endpoint requires a JWE
  # auth token minted from this account for every request, so it is not open,
  # just not disabled. Re-add NO_INGRESS once the 403 stops reproducing.
  description = "MicroVM instances are dynamic runtime resources, not Terraform-managed. This is the CLI call that launches one ephemeral runner from the image above."
  value = join(" ", [
    "aws lambda-microvms run-microvm",
    "--image-identifier ${awscc_lambda_microvm_image.gh_runner.image_arn}",
    "--execution-role-arn ${aws_iam_role.microvm_execution_role.arn}",
    "--maximum-duration-in-seconds 14400",
    "--region ${var.aws_region}",
  ])
}

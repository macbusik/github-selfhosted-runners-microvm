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

output "run_microvm_example_command" {
  description = "MicroVM instances are dynamic runtime resources, not Terraform-managed. This is the CLI call that launches one ephemeral runner from the image above."
  value = join(" ", [
    "aws lambda-microvms run-microvm",
    "--image-identifier ${awscc_lambda_microvm_image.gh_runner.image_arn}",
    "--execution-role-arn ${aws_iam_role.microvm_execution_role.arn}",
    "--ingress-network-connectors arn:aws:lambda:${var.aws_region}:aws:network-connector:aws-network-connector:NO_INGRESS",
    "--maximum-duration-in-seconds 14400",
  ])
}

variable "aws_region" {
  description = "AWS region to deploy into. Lambda MicroVMs is only available in a handful of regions at launch."
  type        = string
  default     = "eu-west-1"

  validation {
    condition = contains(
      ["us-east-1", "us-east-2", "us-west-2", "eu-west-1", "ap-northeast-1"],
      var.aws_region
    )
    error_message = "Lambda MicroVMs (as of 2026-07) is only available in us-east-1, us-east-2, us-west-2, eu-west-1 and ap-northeast-1. Check https://aws.amazon.com/about-aws/whats-new/2026/06/aws-lambda-microvms/ for the current list before changing this."
  }
}

variable "name_prefix" {
  description = "Prefix used when naming AWS resources created by this stack."
  type        = string
  default     = "gh-runner-microvm"
}

variable "github_owner" {
  description = "GitHub organization or user that owns the target repository."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository the ephemeral runner registers against (repo-level runner, not org-level)."
  type        = string
}

variable "runner_labels" {
  description = "Comma-separated labels the runner registers with. Reference these in a workflow's `runs-on:`."
  type        = string
  default     = "self-hosted,microvm,ephemeral,linux,arm64"
}

variable "base_image_version" {
  description = <<-EOT
    Version identifier of the arn:aws:lambda:<region>:aws:microvm-image:al2023-1
    base image. Cannot be empty - Lambda MicroVMs rejects "" ("latest" is not
    a valid value here, unlike --base-image-version being omitted in the CLI).
    Look up the current AVAILABLE version with:
      aws lambda-microvms list-managed-microvm-image-versions \
        --image-identifier arn:aws:lambda:<region>:aws:microvm-image:al2023-1
  EOT
  type        = string
}

variable "github_app_secret_name" {
  description = <<-EOT
    Override for the Secrets Manager secret name. By default the name is
    derived as <name_prefix>/<github_owner>-<github_repo>/github-app. Set this
    only to pin a pre-existing secret whose name doesn't match the derived
    pattern - renaming a secret forces destroy+create in Terraform, which
    would wipe the stored GitHub App credentials (populated out-of-band) and
    orphan any MicroVM image that has the old secret ARN baked into its
    environment variables.
  EOT
  type        = string
  default     = null
}

variable "dispatcher_max_duration_seconds" {
  description = <<-EOT
    maximum-duration-in-seconds dla MicroVM-ow odpalanych przez dispatcher.
    To takze siatka bezpieczenstwa na "osierocone" VM-y (redelivery webhooka,
    job anulowany w kolejce): taki VM nigdy nie dostanie joba i zyje az do
    tego limitu. Krotszy limit = mniejszy koszt pomylki, ale tez maksymalny
    czas trwania joba.
  EOT
  type        = number
  default     = 14400
}

variable "runner_image_baseline_memory_mib" {
  description = "Baseline memory (MiB) for the MicroVM. vCPU scales proportionally with memory (2048 MiB = 1 vCPU). Can burst to 4x baseline. Valid steps: 512, 1024, 2048, 4096, 8192."
  type        = number
  default     = 2048
}

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

variable "runner_image_baseline_memory_mib" {
  description = "Baseline memory (MiB) for the MicroVM. vCPU scales proportionally with memory (2048 MiB = 1 vCPU). Can burst to 4x baseline. Valid steps: 512, 1024, 2048, 4096, 8192."
  type        = number
  default     = 2048
}

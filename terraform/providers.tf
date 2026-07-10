terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.60"
    }
    awscc = {
      source = "hashicorp/awscc"
      # awscc_lambda_microvm_image first shipped in 1.90.0 (2026-06-24),
      # two days after Lambda MicroVMs itself went GA (2026-06-22). Verified
      # against provider docs: the resource does not exist in the v1.89.0 tag.
      version = ">= 1.90.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

provider "awscc" {
  region = var.aws_region
}

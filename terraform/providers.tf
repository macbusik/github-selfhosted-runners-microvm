terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.60"
    }
    awscc = {
      source = "hashicorp/awscc"
      # awscc_lambda_microvm_image first shipped in 1.89.0 (2026-06-17),
      # just days before Lambda MicroVMs itself went GA (2026-06-22).
      version = ">= 1.89.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

provider "awscc" {
  region = var.aws_region
}

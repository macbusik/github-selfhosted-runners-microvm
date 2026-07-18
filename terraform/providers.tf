terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.60"
    }
    # awscc removed 2026-07: the MicroVM image is now managed through
    # CloudFormation (aws_cloudformation_stack in main.tf) because of two
    # confirmed awscc defects - see ../MIGRATION_PLAN.md.
  }
}

provider "aws" {
  region = var.aws_region
}

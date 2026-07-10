terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.60"
    }
  }

  # Deliberately local state, same as ../terraform. This stack is disposable
  # by design (spin up, build the runner image, tear down) - see README.md
  # for why it lives in its own state instead of being folded into the core
  # stack, and why a remote backend isn't worth the overhead yet.
}

provider "aws" {
  region = var.aws_region
}

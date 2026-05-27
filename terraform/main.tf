terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }

  # Remote state lives in an S3 bucket you create once during bootstrap.
  # Pass the bucket name via:
  #   terraform init -backend-config="bucket=tf-state-semblo-<random>" \
  #                  -backend-config="dynamodb_table=tf-state-semblo-lock"
  # See deploy docs (DEPLOYMENT.md) for the one-time bootstrap steps.
  backend "s3" {
    key     = "semblo/prod/terraform.tfstate"
    region  = "eu-central-1"
    encrypt = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "semblo"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

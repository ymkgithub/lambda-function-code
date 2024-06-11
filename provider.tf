terraform {
  required_version = ">= 1.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 3.0"
    }
  }
 backend "s3" {
    bucket = "lambda-tf-bucket-github-runner"
    key    = "Lambda_TF_State/terraform.tfstate"
    region = "us-east-1"
  }
}

provider "aws" {
  region = "us-east-1"
}

terraform {
  required_version = ">= 1.7"

required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
  
# Adding Backend as S3 for Remote State Storage
backend "s3" {
    bucket = "lambda-tf-bucket-github-runner"
    key    = "Lambda_TF_State/terraform.tfstate"
    region = "us-east-1"
  }
}

provider "aws" {
  region  = "us-east-1"
}

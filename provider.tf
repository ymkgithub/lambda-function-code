# Terraform Block
terraform {
  required_version = ">= 1.7" # which means any version equal & above 0.14 like 0.15, 0.16 etc and < 1.xx
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
  # Adding Backend as S3 for Remote State Storage
  backend "s3" {
    bucket = "lambda-tf-bucket-github-runner"
    key    = "lamda/terraform.tfstate"
    region = "us-east-1"

  }
}

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }

  # State PROPRIO, separado do cluster. O bootstrap do bucket e da tabela de lock
  # e feito fora deste state para evitar a dependencia circular do backend.
  backend "s3" {
    bucket         = "soat-tc3-tfstate-mateus-paz"
    key            = "database/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "soat-tc3-tflock"
    encrypt        = true
  }
}

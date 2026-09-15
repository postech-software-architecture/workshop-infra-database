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
  # Backend parcial: bucket, region e dynamodb_table chegam por -backend-config
  # no init, a partir das variables TFSTATE_BUCKET e TFSTATE_LOCK_TABLE do
  # Environment. Um bloco backend nao aceita interpolacao, entao esta e a unica
  # forma de nao fixar o nome da conta no codigo.
  backend "s3" {
    key     = "database/terraform.tfstate"
    encrypt = true
  }
}

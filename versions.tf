terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }

  # State PROPRIO, separado do cluster. Chave 'database/' (o cluster usa 'cluster/').
  # Comentado ate o spike da W0 confirmar S3+DynamoDB no Academy.
  # backend "s3" {
  #   bucket         = "soat-tc3-tfstate"
  #   key            = "database/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "soat-tc3-tflock"
  #   encrypt        = true
  # }
}

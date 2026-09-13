variable "region" {
  description = "Regiao AWS"
  type        = string
  default     = "us-east-1"

  validation {
    condition     = var.region == "us-east-1"
    error_message = "Este ambiente Academy e o backend da W3 estao fixados em us-east-1."
  }
}

variable "project" {
  description = "Prefixo de nomeacao dos recursos"
  type        = string
  default     = "workshop"

  validation {
    condition     = var.project == "workshop"
    error_message = "O contrato W3 fixa os nomes workshop-db, workshop-db-subnets e workshop-db-sg."
  }
}

variable "db_name" {
  description = "Nome do banco"
  type        = string
  default     = "workshop"

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9_]{0,62}$", var.db_name))
    error_message = "db_name deve comecar com letra e conter apenas letras, numeros ou underscore (maximo 63 caracteres)."
  }
}

variable "db_username" {
  description = "Usuario master do banco"
  type        = string
  default     = "workshop"

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9_]{0,62}$", var.db_username))
    error_message = "db_username deve comecar com letra e conter apenas letras, numeros ou underscore (maximo 63 caracteres)."
  }
}

variable "db_password" {
  description = <<-DESC
    Senha do banco. NAO tem default de proposito: vem de Environment secret
    (TF_VAR_db_password), a mesma consumida pelo k8s Secret e pela Lambda.
    Nao e publicada como output. Como todo atributo gerenciado pelo Terraform,
    fica armazenada no state remoto criptografado e deve ser tratada como segredo.
  DESC
  type        = string
  sensitive   = true

  validation {
    condition = (
      length(var.db_password) >= 8 &&
      length(var.db_password) <= 128 &&
      !can(regex("[\\s/@\"']", var.db_password))
    )
    error_message = "db_password deve ter 8-128 caracteres e nao pode conter espaco, barra, arroba ou aspas."
  }
}

variable "engine_version" {
  description = "Versao do PostgreSQL"
  type        = string
  default     = "15"

  validation {
    condition     = can(regex("^15(\\.[0-9]+)?$", var.engine_version))
    error_message = "A W3 usa PostgreSQL major version 15."
  }
}

variable "instance_class" {
  description = "Classe da instancia"
  type        = string
  default     = "db.t3.micro"

  validation {
    condition     = can(regex("^db\\.[a-z0-9]+\\.[a-z0-9]+$", var.instance_class))
    error_message = "instance_class deve ser uma classe RDS valida, por exemplo db.t3.micro."
  }
}

variable "allocated_storage" {
  description = "Armazenamento em GB"
  type        = number
  default     = 20

  validation {
    condition     = var.allocated_storage >= 20 && var.allocated_storage <= 65536
    error_message = "allocated_storage deve estar entre 20 e 65536 GiB."
  }
}

variable "backup_retention_days" {
  description = "Dias de retencao de backup automatico. 0 desliga o backup."
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_days >= 0 && var.backup_retention_days <= 35
    error_message = "backup_retention_days deve estar entre 0 e 35."
  }
}

variable "backup_window" {
  description = "Janela de backup (UTC), fora do horario de demonstracao"
  type        = string
  default     = "06:00-07:00"

  validation {
    condition     = can(regex("^[0-2][0-9]:[0-5][0-9]-[0-2][0-9]:[0-5][0-9]$", var.backup_window))
    error_message = "backup_window deve usar o formato UTC hh:mm-hh:mm."
  }
}

variable "maintenance_window" {
  description = "Janela de manutencao (UTC)"
  type        = string
  default     = "sun:07:30-sun:08:30"

  validation {
    condition     = can(regex("^(mon|tue|wed|thu|fri|sat|sun):[0-2][0-9]:[0-5][0-9]-(mon|tue|wed|thu|fri|sat|sun):[0-2][0-9]:[0-5][0-9]$", var.maintenance_window))
    error_message = "maintenance_window deve usar o formato ddd:hh:mm-ddd:hh:mm em UTC."
  }
}

variable "deletion_protection" {
  description = <<-DESC
    Protecao contra delecao. Em ambiente de estudo fica false para permitir
    `terraform destroy` ao final da sessao do Academy.
  DESC
  type        = bool
  default     = false
}

# --- Leitura do contrato do repo de cluster ---

variable "cluster_state_bucket" {
  description = "Bucket do state do cluster. Vazio = usa as vars de fallback abaixo (ADR-005)."
  type        = string
  default     = ""

  validation {
    condition     = var.cluster_state_bucket == "" || can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.cluster_state_bucket))
    error_message = "cluster_state_bucket deve ser vazio ou um nome de bucket S3 valido."
  }
}

variable "vpc_id_fallback" {
  description = "Fallback do contrato quando nao ha backend remoto (artifact contracts/outputs.json)"
  type        = string
  default     = ""

  validation {
    condition     = var.vpc_id_fallback == "" || can(regex("^vpc-[0-9a-f]+$", var.vpc_id_fallback))
    error_message = "vpc_id_fallback deve ser vazio ou um ID de VPC valido."
  }
}

variable "private_subnet_ids_fallback" {
  description = "Fallback do contrato: subnets privadas para o DB subnet group"
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for id in var.private_subnet_ids_fallback : can(regex("^subnet-[0-9a-f]+$", id))])
    error_message = "Cada item de private_subnet_ids_fallback deve ser um ID de subnet valido."
  }
}

variable "db_client_sg_id_fallback" {
  description = "Fallback do contrato: SG de cliente autorizado no ingress 5432"
  type        = string
  default     = ""

  validation {
    condition     = var.db_client_sg_id_fallback == "" || can(regex("^sg-[0-9a-f]+$", var.db_client_sg_id_fallback))
    error_message = "db_client_sg_id_fallback deve ser vazio ou um ID de security group valido."
  }
}

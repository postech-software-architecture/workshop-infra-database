variable "region" {
  description = "Regiao AWS"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Prefixo de nomeacao dos recursos"
  type        = string
  default     = "workshop"
}

variable "db_name" {
  description = "Nome do banco"
  type        = string
  default     = "workshop"
}

variable "db_username" {
  description = "Usuario master do banco"
  type        = string
  default     = "workshop"
}

variable "db_password" {
  description = <<-DESC
    Senha do banco. NAO tem default de proposito: vem de Environment secret
    (TF_VAR_db_password), a mesma consumida pelo k8s Secret e pela Lambda.
    Nunca trafega por remote state.
  DESC
  type        = string
  sensitive   = true
}

variable "engine_version" {
  description = "Versao do PostgreSQL"
  type        = string
  default     = "15"
}

variable "instance_class" {
  description = "Classe da instancia"
  type        = string
  default     = "db.t3.micro"
}

variable "allocated_storage" {
  description = "Armazenamento em GB"
  type        = number
  default     = 20
}

variable "backup_retention_days" {
  description = "Dias de retencao de backup automatico. 0 desliga o backup."
  type        = number
  default     = 7
}

variable "backup_window" {
  description = "Janela de backup (UTC), fora do horario de demonstracao"
  type        = string
  default     = "06:00-07:00"
}

variable "maintenance_window" {
  description = "Janela de manutencao (UTC)"
  type        = string
  default     = "sun:07:30-sun:08:30"
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
}

variable "vpc_id_fallback" {
  description = "Fallback do contrato quando nao ha backend remoto (artifact contracts/outputs.json)"
  type        = string
  default     = ""
}

variable "private_subnet_ids_fallback" {
  description = "Fallback do contrato: subnets privadas para o DB subnet group"
  type        = list(string)
  default     = []
}

variable "db_client_sg_id_fallback" {
  description = "Fallback do contrato: SG de cliente autorizado no ingress 5432"
  type        = string
  default     = ""
}

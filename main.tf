# Repositorio de banco gerenciado — Fase 3.
#
# Escopo: DB subnet group, security group do banco, aws_db_instance PostgreSQL,
# criptografia e backup. State PROPRIO, separado do cluster.
#
# NAO existe aqui: VPC, subnets, EKS, node group, LB Controller — tudo isso vive em
# workshop-infra-kubernetes e e LIDO via contrato, nunca escrito. O `plan` deste repo
# sem nenhum recurso de EKS e criterio do gate G3.
#
# Antes do primeiro apply, o inventario read-only deve consultar separadamente a
# instancia, o subnet group e o SG esperados. Na conta alvo vazia os tres recursos
# serao criados; qualquer objeto preexistente e nao gerenciado exige abortar o apply
# e reconciliar/importar primeiro. Ver README.

locals {
  # Fonte do contrato: remote state quando ha backend; senao as vars de fallback
  # alimentadas pelo artifact contracts/outputs.json (§4 do plano, ADR-005).
  use_remote_state = var.cluster_state_bucket != ""

  vpc_id = local.use_remote_state ? data.terraform_remote_state.cluster[0].outputs.vpc_id : var.vpc_id_fallback

  private_subnet_ids = local.use_remote_state ? data.terraform_remote_state.cluster[0].outputs.private_subnet_ids : var.private_subnet_ids_fallback

  db_client_sg_id = local.use_remote_state ? data.terraform_remote_state.cluster[0].outputs.db_client_sg_id : var.db_client_sg_id_fallback
}

# Leitura READ-ONLY do state do cluster. Este repo nunca escreve nele.
data "terraform_remote_state" "cluster" {
  count = local.use_remote_state ? 1 : 0

  backend = "s3"
  config = {
    bucket = var.cluster_state_bucket
    key    = "cluster/terraform.tfstate"
    region = var.region
  }
}

# --- Subnet group: o banco vive nas subnets PRIVADAS ---
resource "aws_db_subnet_group" "this" {
  name        = "${var.project}-db-subnets"
  description = "Subnets privadas do RDS (contrato: private_subnet_ids do repo de cluster)"
  subnet_ids  = local.private_subnet_ids

  tags = { Project = var.project }

  lifecycle {
    precondition {
      condition     = length(local.private_subnet_ids) >= 2
      error_message = "O contrato do cluster deve fornecer pelo menos duas subnets privadas."
    }
  }
}

# --- Security group do banco ---
# Ingress APENAS do SG de cliente vindo do contrato. Nao ha CIDR aberto, nao ha
# 0.0.0.0/0, e o banco nao e publicamente acessivel.
resource "aws_security_group" "db" {
  name                   = "${var.project}-db-sg"
  description            = "RDS PostgreSQL: ingress 5432 somente do db_client_sg_id"
  vpc_id                 = local.vpc_id
  revoke_rules_on_delete = true

  ingress {
    description     = "Postgres apenas do SG de cliente (nodes do EKS e Lambda)"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [local.db_client_sg_id]
  }

  tags = { Project = var.project }

  lifecycle {
    precondition {
      condition     = local.vpc_id != ""
      error_message = "O contrato do cluster deve fornecer vpc_id."
    }

    precondition {
      condition     = local.db_client_sg_id != ""
      error_message = "O contrato do cluster deve fornecer db_client_sg_id; CIDR nao e aceito como fallback."
    }
  }
}

# --- Instancia PostgreSQL ---
resource "aws_db_instance" "postgres" {
  identifier     = "${var.project}-db"
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.allocated_storage * 2 # autoscaling de storage
  storage_type          = "gp3"
  storage_encrypted     = true # criptografia em repouso

  db_name  = var.db_name
  username = var.db_username
  # Sensitive evita exibicao no CLI, mas o valor fica no state remoto criptografado.
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false # criterio do gate G3

  # Backup e manutencao
  backup_retention_period = var.backup_retention_days
  backup_window           = var.backup_window
  maintenance_window      = var.maintenance_window
  copy_tags_to_snapshot   = true

  # Ambiente de estudo: permite destroy ao fim da sessao do Academy.
  skip_final_snapshot = true
  deletion_protection = var.deletion_protection

  # Observabilidade do banco (a app expõe as metricas de negocio; aqui e infra).
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  # Academy: sem permissao de IAM para criar a role do Enhanced Monitoring.
  monitoring_interval = 0

  auto_minor_version_upgrade = true
  apply_immediately          = true

  tags = { Project = var.project }

  lifecycle {
    # A senha e rotacionada fora do Terraform (Environment secret); nao reconciliar
    # automaticamente uma diferenca nesse atributo.
    ignore_changes = [password]
  }
}

# workshop-infra-database

Banco gerenciado da **Fase 3** do Tech Challenge (SOAT): RDS PostgreSQL em subnets
privadas, com criptografia em repouso, backup automatico e acesso restrito por
security group.

**State proprio**, separado do cluster.

## Fronteira

| | |
|---|---|
| **Contem** | DB subnet group, SG do banco, `aws_db_instance`, backup, criptografia |
| **Nao contem** | VPC, subnets, EKS, node group, LB Controller — vivem em [workshop-infra-kubernetes](https://github.com/postech-software-architecture/workshop-infra-kubernetes) e sao **lidos** via contrato |
| **Nao contem** | Migrations Flyway — permanecem no repo da aplicacao |

A CI verifica a fronteira: o job falha se um `aws_eks_*`/`aws_vpc`/`aws_subnet` aparecer.

## ⚠️ `terraform import` e OBRIGATORIO

Ja existe uma instancia RDS provisionada **e semeada** pelo state antigo (o do repo da
aplicacao, em `infra/eks/`). Rodar `apply` direto num state novo cria um **segundo**
banco e orfana o semeado — destruindo os dados que o checkpoint **G4** usa.

```bash
# 1. Descobrir o identificador real
aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier'

# 2. Importar ANTES de qualquer apply
terraform import aws_db_instance.postgres workshop-db
terraform import aws_db_subnet_group.this workshop-db-subnets
terraform import aws_security_group.db sg-xxxxxxxx

# 3. Conferir que o plan esta VAZIO (ou so com mudancas esperadas)
terraform plan
```

Um `plan` que proponha **criar** `aws_db_instance.postgres` significa que o import
nao foi feito. **Nao aplique.**

## Contrato consumido

Lido do repo de cluster, read-only:

| Output | Uso aqui |
|---|---|
| `private_subnet_ids` | subnets do DB subnet group |
| `vpc_id` | VPC do security group |
| `db_client_sg_id` | **unico** ingress autorizado no 5432 |

Com backend remoto: `cluster_state_bucket = "..."`. Sem backend (fallback do §4,
ADR-005): as vars `*_fallback`, alimentadas pelo artifact `contracts/outputs.json`.

## A senha

`var.db_password` **nao tem default**. Vem de `TF_VAR_db_password`, de Environment
secret — a mesma consumida pelo k8s Secret e pela Lambda.

Ela **nao** e exposta como output. O `outputs.tf` antigo do repo da aplicacao expunha
`db_password` (mesmo com `sensitive = true`), o que a colocava no state — inaceitavel
quando o state passa a ser lido por outros repos. Corrigido nesta extracao.

## Seguranca

- `publicly_accessible = false` — criterio do gate **G3**
- `storage_encrypted = true`
- Ingress 5432 **somente** do `db_client_sg_id`; nenhum CIDR aberto
- `backup_retention_period` 7 dias, janela fora do horario de demonstracao
- `enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]`
- `monitoring_interval = 0` — o Academy nao permite criar a role do Enhanced Monitoring

## Rodar

```bash
terraform fmt -check
terraform init -backend=false && terraform validate   # sem credencial

export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... AWS_SESSION_TOKEN=...
export TF_VAR_db_password='...'
terraform init && terraform plan
```

## Agentes

Ver [.claude/agents/README.md](.claude/agents/README.md). Dono: `terraform-database`.

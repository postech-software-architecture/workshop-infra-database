# Agente: Terraform Database (RDS PostgreSQL gerenciado)

## Responsabilidade
Autorar e operar o Terraform do repositório `workshop-infra-database`: DB subnet group,
security group do banco, `aws_db_instance` PostgreSQL, criptografia, backup/retenção e
política de snapshot. State **próprio**, separado do cluster.

Atua na fase **W3**. Na conta alvo atual, o inventario da W2 confirmou que nao ha RDS
legado a preservar; o primeiro provisionamento esperado e uma criacao nova.

## Fronteira

A regra que sustenta o paralelismo de 4 agentes: **exatamente um agente escreve num dado
caminho**. Se você precisar de uma mudança fora da lista Owns, peça ao agente dono — não edite.

### Owns
- Repo `workshop-infra-database` (todo): `main.tf`, `variables.tf`, `outputs.tf`,
  `providers.tf`, `versions.tf`, `backend.tf`, `terraform.tfvars.example`,
  `environments/**`, `docs/database-infrastructure.md`, `README.md`
- Recursos: `aws_db_subnet_group`, `aws_security_group` **do banco**, `aws_db_instance`,
  parameter/option groups se usados
- Outputs não sensíveis: `db_host`, `db_port`, `db_name`, `db_username`

### Não toca
- VPC, subnets, NAT, EKS, node group, `metrics-server`, LB Controller
  (`terraform-cluster` é dono) — você **lê** o state `cluster/`, nunca escreve nele
- O SG **de cliente** do banco (`db_client_sg_id`) — produzido por `terraform-cluster`
- Migrations Flyway em `src/main/resources/db/migration/` (o agente `migration` é dono; as
  migrations **permanecem** no repo da aplicação)
- Entidades JPA, repositórios, consultas, `src/**`
- Terraform da Lambda / API Gateway (`serverless-lambda` é dono)
- `.github/workflows/**` — corpo do YAML é de `cicd-pipelines`

## Contexto do projeto

### Estado real verificado (o repo ganha do doc de planejamento)
- O repositório possui state próprio e não gerencia VPC, EKS ou node group.
- A conta alvo atual não contém a instância RDS legada da fase anterior; criação nova é
  permitida após inventariar separadamente instância, subnet group e security group.
- O ingress do banco usa apenas **`db_client_sg_id`** do contrato de outputs, sem CIDR,
  permitindo autorizar os consumidores associados a esse SG.
- A senha não é output nem atravessa `terraform_remote_state`; como atributo gerenciado,
  porém, ela fica no state remoto criptografado.
- A aplicação usa PostgreSQL 15, Flyway com **19 migrations**, JPA + JDBC, Testcontainers, 17
  tabelas. Já existe `V0.20260507210000__seed_demo_workshop_data.sql`.
- O backend remoto S3 usa a chave isolada `database/terraform.tfstate`, criptografia e
  lock em DynamoDB; o bootstrap desses dois serviços fica fora deste state.

### Por que o banco tem repo e state próprios
O problema da Fase 3 não é escolher banco novo — é **separar o ciclo de vida do banco do
ciclo de vida do EKS**. Destruir o cluster para economizar crédito do Academy não pode
destruir os dados semeados que o checkpoint G4 usa.

## Inventário obrigatório; import condicional

Import não é uma etapa automática quando a conta alvo está vazia. Antes do primeiro
apply, verifique individualmente os três nomes gerenciados:

```bash
# Conta vazia: cada consulta deve confirmar ausencia
aws rds describe-db-instances --db-instance-identifier workshop-db
aws rds describe-db-subnet-groups --db-subnet-group-name workshop-db-subnets
aws ec2 describe-security-groups \
  --filters Name=vpc-id,Values=vpc-xxxxxxxx Name=group-name,Values=workshop-db-sg

# Se um recurso preexistente for confirmado como adotavel, importe somente ele
terraform import aws_db_instance.postgres      workshop-db
terraform import aws_db_subnet_group.this      workshop-db-subnets
terraform import aws_security_group.db         sg-xxxxxxxxxxxx

# 3. Provar que o import ficou fiel: o plan tem de ser vazio (ou só diferenças intencionais)
terraform plan
# "No changes. Your infrastructure matches the configuration."
```

Regras não negociáveis:
- **Nunca** rodar o primeiro `apply` sem inventariar os três tipos de recurso. A ausência
  da instância não prova a ausência do subnet group ou do SG.
- A existência do SG é determinada por VPC + nome, sem filtro de tag. Se existir,
  valide `Project=workshop` separadamente; tag divergente exige reconciliação/import.
- Se qualquer objeto existir fora deste state, **aborte** e reconcilie/importe; criação só
  é permitida quando o inventário dos três estiver vazio.
- **Nunca** deixar dois projetos gerenciarem o mesmo recurso.
- Se o `plan` pós-import quiser **substituir** (`must be replaced`) a instância, **pare**:
  ajuste a config até virar `update in-place` ou `no changes`. Replace = perda de dados.

## Padrão dos recursos

```hcl
# Lê o contrato de outputs do cluster — READ-ONLY. Nunca escreve nesse state.
data "terraform_remote_state" "cluster" {
  backend = "s3"
  config = {
    bucket = var.tfstate_bucket
    key    = "cluster/terraform.tfstate"
    region = var.region
  }
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.project}-db-subnets"
  subnet_ids = data.terraform_remote_state.cluster.outputs.private_subnet_ids

  tags = { Project = var.project, Environment = var.environment }
}

resource "aws_security_group" "db" {
  name        = "${var.project}-db-sg"
  description = "RDS PostgreSQL — ingress apenas de clientes autorizados"
  vpc_id      = data.terraform_remote_state.cluster.outputs.vpc_id

  # Fonte explicita: SOMENTE o SG de cliente do banco produzido pela fundação.
  # Nao usar cidr_blocks. Nao usar 0.0.0.0/0. O SG de cliente e anexado aos nodes
  # do EKS e a Lambda, entao um unico ingress cobre os dois consumidores.
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [data.terraform_remote_state.cluster.outputs.db_client_sg_id]
  }

  tags = { Project = var.project, Environment = var.environment }
}

resource "aws_db_instance" "postgres" {
  identifier     = "${var.project}-db"
  engine         = "postgres"
  engine_version = var.engine_version # fixada e documentada — hoje "15"
  instance_class = var.instance_class # Academy: db.t3.micro

  allocated_storage     = var.allocated_storage
  storage_encrypted     = true
  db_name               = var.db_name
  username              = var.db_username
  password              = var.db_password # sensitive; vem de Environment secret

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]

  publicly_accessible     = false # NUNCA true. Checado no gate G3.
  multi_az                = var.multi_az                # Academy: false (custo)
  backup_retention_period = var.backup_retention_period  # Academy: curto, mas > 0
  deletion_protection     = var.deletion_protection
  skip_final_snapshot     = var.skip_final_snapshot

  lifecycle {
    # Protege contra recriacao por mudanca trivial de atributo.
    prevent_destroy = false # true em prod conceitual; false no Academy para permitir reset
  }

  tags = { Project = var.project, Environment = var.environment }
}
```

## Senha: nunca por output; protegida no state

```hcl
variable "db_password" {
  description = "Senha do usuário master do RDS. Vem de Environment secret, nunca de tfvars versionado."
  type        = string
  sensitive   = true
}
```

- **`db_password` não é output e não trafega por `terraform_remote_state`.** Vive em
  Environment secret do GitHub e é consumido igualmente pelo Kubernetes e pela Lambda.
- O valor fica no state do banco porque é atributo do `aws_db_instance`; o backend S3
  criptografado e suas permissões são parte da proteção. `sensitive = true` apenas evita
  exposição normal no CLI/log, não remove o valor do state.
- `sensitive = true` na variável, e `::add-mask::` no step da pipeline que a manipula.
- Nada de valor default versionado. Nada de `terraform.tfvars` no git — só o `.example`.
- Não use `lifecycle.ignore_changes` em `password`: alterar `TF_VAR_db_password` deve
  rotacionar a senha master in-place. Preconfigure a mesma senha nos Environments dos
  consumidores e faça o redeploy deles na mesma janela operacional do apply.

Outputs permitidos (não sensíveis):

```hcl
output "db_host" { value = aws_db_instance.postgres.address }
output "db_port" { value = aws_db_instance.postgres.port }
output "db_name" { value = var.db_name }
output "db_username" { value = var.db_username }
```

Consumidores: `k8s-workloads` (ConfigMap/Secret do Deployment) e `serverless-lambda` (env da
Function, que lê o state `database/`).

## Academy versus produção conceitual

Distinga concessão acadêmica de atributo da arquitetura corporativa no README e no diagrama —
não afirme HA onde não há.

| Parâmetro | Academy | Produção documentada |
|---|---|---|
| classe | `db.t3.micro` | dimensionada por carga |
| Multi-AZ | `false` (custo) | `true` para HA |
| backup retention | curto, suficiente para demo | conforme RPO |
| final snapshot | pode ser omitido no sandbox | obrigatório em mudanças destrutivas |
| deletion protection | pode impedir reset rápido | habilitada |
| credencial | Environment secret temporário | Secrets Manager com rotação |

## Backend

```hcl
terraform {
  backend "s3" {
    bucket         = "soat-tc3-tfstate-mateus-paz"
    key            = "database/terraform.tfstate" # chave PRÓPRIA, separada de cluster/
    region         = "us-east-1"
    dynamodb_table = "soat-tc3-tflock"
    encrypt        = true
  }
}
```

O spike W0 validou S3 e DynamoDB no Academy. `contracts/outputs.json` permanece fallback
para o contrato de entrada do cluster, não para o state deste repositório.

## Gate

### G3 (fim da W3) — você é dono de 3 dos 4 critérios
```bash
terraform fmt -check
terraform init -backend=false
terraform validate

# 1. plan cria APENAS recursos de banco — zero EKS/node group
terraform plan -no-color | grep -cE 'aws_eks_|module\.vpc|module\.eks'   # deve ser 0

# 2. simetria: o plan do repo de CLUSTER não pode ter aws_db_*
#    (rodar no repo workshop-infra-kubernetes)
terraform plan -no-color | grep -c 'aws_db_'                              # deve ser 0

# 3. RDS não é público
aws rds describe-db-instances --db-instance-identifier workshop-db \
  --query 'DBInstances[0].PubliclyAccessible'                             # false

# 4. conta vazia: plan cria os tres objetos esperados; recurso existente exige import
terraform plan   # sem replacement nem mudancas destrutivas inesperadas
```

**Conectividade provada de dentro da VPC, não da internet** — um pod no EKS conecta no RDS:

```bash
kubectl -n workshop run pg-probe --rm -it --restart=Never \
  --image=postgres:15-alpine -- \
  psql "host=$DB_HOST port=5432 dbname=$DB_NAME user=$DB_USER" -c 'SELECT 1'
```

### Validações de schema (co-agendadas com `migration` + `tests` na W3)
Você não escreve migrations, mas o gate é conjunto:
```bash
TESTCONTAINERS_HOST_OVERRIDE=localhost ./mvnw verify
```
- Flyway aplica as 19 migrations em banco vazio
- Flyway atualiza uma cópia do schema da Fase 2 sem erro
- Hibernate `ddl-auto=validate` inicia a aplicação
- Consultas de dados órfãos retornam **zero** antes de habilitar as 4 FKs candidatas

## Riscos que você mitiga
| Risco | Mitigação |
|---|---|
| **Colidir com recurso fora do state** | Inventário separado dos três nomes; existência exige abortar, reconciliar/importar |
| Terraform recriar o RDS por mudança trivial | State isolado, `plan` revisado linha a linha, `apply` com aprovação; `must be replaced` = pare |
| Lambda não alcançar o RDS | Subnets privadas + rota + ingress do `db_client_sg_id`; teste de conectividade dedicado a partir da Lambda |
| Expor senha em output ou log | Sem output de senha; `sensitive = true`; `::add-mask::`; senha só via Environment secret |
| Adicionar FK com dados órfãos | Relatório de órfãos (W2, read-only) antes da migration da W3 — dono é `migration` |
| Banco público por descuido | `publicly_accessible = false` + policy check na pipeline barrando `true` |

## Como usar este agente
1. Ler a configuração atual deste repositório e o contrato de outputs do cluster antes
   de alterar recursos; o código versionado ganha de snapshots antigos do planejamento.
2. **Antes do primeiro apply:** inventariar instância, subnet group e SG. Com os três
   ausentes, revisar a criação nova; se algum existir, abortar e reconciliar/importar.
3. **W3:** consumir `cluster/` via `terraform_remote_state` read-only e provar no plan
   ingress via `db_client_sg_id`, `storage_encrypted` e `publicly_accessible = false`.
4. Confirmar que nenhum outro state gerencia os mesmos recursos.
5. Criar pipeline `fmt` / `validate` / `plan` / `apply` com gate / `destroy` manual e protegida.
6. Não escrever migrations, entidades JPA nem consultas — isso fica na aplicação.

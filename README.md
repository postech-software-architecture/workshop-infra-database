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

## Primeiro apply: inventario antes de criar ou importar

A conta alvo atual esta vazia, portanto o caminho esperado e a **criacao nova** dos
tres recursos. Isso nao elimina a guarda contra colisao: imediatamente antes do
primeiro `plan/apply`, consulte separadamente cada nome gerenciado:

```bash
# Instancia: deve retornar vazio ou DBInstanceNotFound
aws rds describe-db-instances --db-instance-identifier workshop-db

# Subnet group: deve retornar vazio ou DBSubnetGroupNotFoundFault
aws rds describe-db-subnet-groups --db-subnet-group-name workshop-db-subnets

# Security group: a lista deve estar vazia
aws ec2 describe-security-groups \
  --filters Name=group-name,Values=workshop-db-sg \
            Name=tag:Project,Values=workshop
```

Somente quando **os tres** resultados confirmarem ausencia o `plan` pode propor criar
`workshop-db`, `workshop-db-subnets` e `workshop-db-sg`. Se qualquer objeto existir
sem estar no state `database/terraform.tfstate`, **aborte**: identifique sua origem,
reconcilie a configuracao e importe o recurso correspondente antes de aplicar. Nunca
assuma que a ausencia da instancia prova a ausencia do subnet group ou do SG.

Exemplo de recuperacao, somente depois de confirmar que o objeto existente deve ser
adotado por este state:

```bash
terraform import aws_db_instance.postgres workshop-db
terraform import aws_db_subnet_group.this workshop-db-subnets
terraform import aws_security_group.db sg-xxxxxxxx
terraform plan # sem replacement nem mudanca destrutiva inesperada
```

## Contrato consumido

Lido do repo de cluster, read-only:

| Output | Uso aqui |
|---|---|
| `private_subnet_ids` | subnets do DB subnet group |
| `vpc_id` | VPC do security group |
| `db_client_sg_id` | **unico** ingress autorizado no 5432 |

Com backend remoto: `cluster_state_bucket = "..."`. Sem backend (fallback do §4,
ADR-005): as vars `*_fallback`, alimentadas pelo artifact `contracts/outputs.json`.

## Backend e senha

O backend S3 esta ativo em `versions.tf` com:

| Campo | Valor |
|---|---|
| bucket | `soat-tc3-tfstate-mateus-paz` |
| key | `database/terraform.tfstate` |
| regiao | `us-east-1` |
| lock DynamoDB | `soat-tc3-tflock` |
| criptografia | habilitada |

Bucket e tabela sao o bootstrap externo validado na W0 e precisam existir antes do
`terraform init` com backend. `terraform init -backend=false` continua disponivel
para validacao estatica sem credenciais.

`var.db_password` **nao tem default**. Vem de `TF_VAR_db_password`, de Environment
secret — a mesma consumida pelo k8s Secret e pela Lambda.

Ela **nao** e exposta como output e `sensitive = true` impede sua exibicao normal no
CLI. Contudo, o provider precisa armazenar o atributo no state para gerenciar o RDS:
a senha fica no state remoto criptografado. Portanto, acesso ao bucket/state deve ser
restrito; `sensitive` nao remove o dado do state. Consumidores recebem a mesma senha
por secret do Environment, nunca via `terraform_remote_state`.

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
terraform init -backend=false
terraform validate # sem credencial

export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... AWS_SESSION_TOKEN=...
export TF_VAR_db_password='...'
terraform init && terraform plan
```

Antes do primeiro apply, execute o inventario dos tres objetos descrito acima. Revise
o plan: este repo pode criar somente subnet group, SG e instancia RDS; deve haver
zero recursos de VPC, EKS ou node group. `publicly_accessible = false`, criptografia e
ingress exclusivamente por `db_client_sg_id` sao invariantes da entrega.

## Pipelines operacionais

| Workflow | Gatilho | Protecao principal |
|---|---|---|
| `ci.yml` | push/PR | fmt/validate e gates estaticos de fronteira, RDS privado, criptografia e SG sem CIDR |
| `terraform-plan.yml` | PR | inventario AWS x state e gates sobre o plan real; publica apenas texto por 7 dias |
| `terraform-apply.yml` | manual na `main` | texto `APLICAR DATABASE PROD`, Environment `prod`, inventario e bloqueio de replace/destroy |
| `terraform-destroy.yml` | manual na `main` | texto `DESTRUIR DATABASE ANTES DO CLUSTER`, Environment `prod` e destroy isolado |

Os workflows AWS exigem `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
`AWS_SESSION_TOKEN` e `DB_PASSWORD` no Environment `prod`. Credenciais do Academy
expiradas falham antes do `terraform init`. O bucket
`soat-tc3-tfstate-mateus-paz` e a tabela `soat-tc3-tflock` sao bootstrap externo:
devem estar ativos antes do plan/apply/destroy e nunca sao removidos por estes
workflows. No Academy, o destroy nao cria snapshot persistente, coerente com
`skip_final_snapshot = true`, para nao deixar custo residual fora do state.

Enquanto nao houver uma sessao Academy valida, mantenha a repository variable
`AWS_CREDENTIALS_READY=false`: o workflow de plan fica explicitamente ignorado e os
gates estaticos da CI continuam rodando. Depois de renovar as quatro secrets acima,
defina a variable como `true` e atualize o PR para executar o plan real.

O inventario aceita somente dois estados completos: os tres objetos ausentes na AWS
e no state (`CREATE`), ou os tres presentes em ambos (`MANAGED`). Recurso apenas na
AWS exige import/reconciliacao; recurso apenas no state indica drift; topologia
parcial tambem bloqueia. O destroy do banco deve terminar **antes** do destroy do
cluster, pois o banco consome a VPC e as subnets do state `cluster/`.

## Agentes

Ver [.claude/agents/README.md](.claude/agents/README.md). Dono: `terraform-database`.

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

A CI exige exatamente `aws_db_instance.postgres`, `aws_db_subnet_group.this` e
`aws_security_group.db`. Qualquer outro endereco gerenciado e bloqueado, inclusive
outro recurso dos mesmos tipos permitidos.

## Primeiro apply: inventario antes de criar ou importar

A conta alvo atual esta vazia, portanto o caminho esperado e a **criacao nova** dos
tres recursos. Isso nao elimina a guarda contra colisao: imediatamente antes do
primeiro `plan/apply`, consulte separadamente cada nome gerenciado:

```bash
# Instancia: deve retornar vazio ou DBInstanceNotFound
aws rds describe-db-instances --db-instance-identifier workshop-db

# Subnet group: deve retornar vazio ou DBSubnetGroupNotFoundFault
aws rds describe-db-subnet-groups --db-subnet-group-name workshop-db-subnets

# Security group: consulte existencia pela chave VPC + nome, sem filtrar por tag
aws ec2 describe-security-groups \
  --filters Name=vpc-id,Values=vpc-xxxxxxxx \
            Name=group-name,Values=workshop-db-sg
```

Somente quando **os tres** resultados confirmarem ausencia o `plan` pode propor criar
`workshop-db`, `workshop-db-subnets` e `workshop-db-sg`. Se qualquer objeto existir
sem estar no state `database/terraform.tfstate`, **aborte**: identifique sua origem,
reconcilie a configuracao e importe o recurso correspondente antes de aplicar. Nunca
assuma que a ausencia da instancia prova a ausencia do subnet group ou do SG.

Se o SG existir, valide separadamente que sua tag `Project` e exatamente `workshop`.
Um SG de mesmo nome sem a tag esperada ainda existe e causa colisao; ele deve ser
reconciliado ou importado, nunca ignorado por um filtro de tags. Os workflows fazem
essas duas verificacoes em sequencia.

O inventario anterior ao primeiro plan le os outputs necessarios diretamente do
objeto `cluster/terraform.tfstate` no S3. Ele nao usa `terraform console`, pois o
state deste repositorio ainda esta vazio nesse momento e data sources ainda seriam
reportados como valores desconhecidos.

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
| bucket | variable `TFSTATE_BUCKET` do Environment `prod` |
| key | `database/terraform.tfstate` |
| regiao | `us-east-1` |
| lock DynamoDB | variable `TFSTATE_LOCK_TABLE` do Environment `prod` |
| criptografia | habilitada |

Bucket e tabela sao o bootstrap externo validado na W0 e precisam existir antes do
`terraform init` com backend. `terraform init -backend=false` continua disponivel
para validacao estatica sem credenciais.

O preflight comum de plan/apply/destroy tambem exige `Versioning=Enabled`,
criptografia default (`AES256` ou `aws:kms`) e as quatro flags de Public Access Block
em `true`: `BlockPublicAcls`, `IgnorePublicAcls`, `BlockPublicPolicy` e
`RestrictPublicBuckets`. A existencia isolada do bucket nao libera uma operacao.

`var.db_password` **nao tem default**. Vem de `TF_VAR_db_password`, de Environment
secret — a mesma consumida pelo k8s Secret e pela Lambda.

Ela **nao** e exposta como output e `sensitive = true` impede sua exibicao normal no
CLI. Contudo, o provider precisa armazenar o atributo no state para gerenciar o RDS:
a senha fica no state remoto criptografado. Portanto, acesso ao bucket/state deve ser
restrito; `sensitive` nao remove o dado do state. Consumidores recebem a mesma senha
por secret do Environment, nunca via `terraform_remote_state`.

Alterar `DB_PASSWORD` e executar o apply **rotaciona a senha master in-place**; o
Terraform nao ignora drift desse atributo. Trate a rotacao como uma unica janela
atomica com os consumidores:

1. gere a nova senha e preconfigure o mesmo valor nos Environments `prod` deste repo,
   da aplicacao e de qualquer Lambda consumidora, sem redeploy antecipado;
2. execute `terraform-plan.yml` e depois `terraform-apply.yml` na `main`;
3. assim que o RDS concluir a modificacao, redeploy os consumidores para carregar o
   valor ja preparado e valide a conexao;
4. mantenha o valor anterior protegido ate concluir a validacao, para permitir uma
   rotacao de rollback coordenada se necessario.

Nao altere somente um dos lados: apos o apply, qualquer workload ainda configurado
com a senha anterior perde acesso ao banco.

## Seguranca

- `publicly_accessible = false` — criterio do gate **G3**
- `storage_encrypted = true`
- Ingress 5432 **somente** do `db_client_sg_id`; nenhum CIDR aberto
- `backup_retention_period` 7 dias, janela fora do horario de demonstracao
- `monitoring_interval = 0` — o Academy nao permite criar a role do Enhanced Monitoring
- exports de logs do RDS desabilitados neste ambiente Academy para nao criar CloudWatch
  Log Groups fora deste state, que sobreviveriam ao destroy e poderiam deixar custo residual

## Rodar

```bash
terraform fmt -check
terraform init -backend=false
terraform validate # sem credencial

export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... AWS_SESSION_TOKEN=...
export TF_VAR_db_password='...'
terraform init && terraform plan
```

Antes do primeiro apply, execute o inventario dos tres objetos descrito acima. State,
plan e destroy devem conter exatamente os tres enderecos canonicos, sem recurso extra
nem mesmo dos mesmos tipos. `publicly_accessible = false`, criptografia, subnet group
esperado e ingress TCP/5432 exclusivamente do `db_client_sg_id` sao invariantes da
entrega e voltam a ser consultados diretamente na AWS depois do apply.

## Pipelines operacionais

| Workflow | Gatilho | Protecao principal |
|---|---|---|
| `ci.yml` | push/PR | fmt/validate e gates estaticos de fronteira, RDS privado, criptografia e SG sem CIDR |
| `terraform-plan.yml` | manual na `main` | texto `PLANEJAR DATABASE PROD`, Environment `prod`, inventario AWS x state e gates sobre o plan real |
| `terraform-apply.yml` | manual na `main` | texto `APLICAR DATABASE PROD`, Environment `prod`, inventario e bloqueio de replace/destroy |
| `terraform-destroy.yml` | manual na `main` | texto `DESTRUIR DATABASE ANTES DO CLUSTER`, Environment `prod` e destroy isolado |

Os workflows AWS exigem `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
`AWS_SESSION_TOKEN` e `DB_PASSWORD` no Environment `prod`. Credenciais do Academy
expiradas falham antes do `terraform init`. O bucket
O bucket da variable `TFSTATE_BUCKET` e a tabela de `TFSTATE_LOCK_TABLE` sao bootstrap externo:
devem estar ativos antes do plan/apply/destroy e nunca sao removidos por estes
workflows. O preflight exige versionamento, criptografia, bloqueio publico completo e
lock ativo antes de qualquer operacao. No Academy, o destroy nao cria snapshot
persistente, coerente com `skip_final_snapshot = true`, para nao deixar custo residual
fora do state.

Pull requests nunca recebem credenciais AWS nem `DB_PASSWORD`: executam apenas
fmt/validate e politicas estaticas em `ci.yml`. O plan real acontece somente depois
do merge, por `workflow_dispatch` na `main`, durante uma janela Academy valida, com
confirmacao textual e aprovacao/protecao do Environment `prod`.

O inventario aceita somente dois estados completos: os tres objetos ausentes na AWS
e no state (`CREATE`), ou os tres presentes em ambos (`MANAGED`). Recurso apenas na
AWS exige import/reconciliacao; recurso apenas no state indica drift; topologia
parcial tambem bloqueia. O destroy do banco deve terminar **antes** do destroy do
cluster, pois o banco consome a VPC e as subnets do state `cluster/`.

## Agentes

Ver [.claude/agents/README.md](.claude/agents/README.md). Dono: `terraform-database`.

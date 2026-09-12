#!/usr/bin/env bash
set -Eeuo pipefail

require_managed="${REQUIRE_MANAGED:-false}"
state_list="${RUNNER_TEMP:-/tmp}/database-state-list.txt"
state_error="${RUNNER_TEMP:-/tmp}/database-state-error.txt"

if ! terraform state list >"${state_list}" 2>"${state_error}"; then
  if grep -q 'No state file was found' "${state_error}"; then
    : >"${state_list}"
  else
    echo "::error::Falha ao ler o state remoto de database."
    exit 1
  fi
fi

state_db=0; grep -Fxq 'aws_db_instance.postgres' "${state_list}" && state_db=1
state_subnets=0; grep -Fxq 'aws_db_subnet_group.this' "${state_list}" && state_subnets=1
state_sg=0; grep -Fxq 'aws_security_group.db' "${state_list}" && state_sg=1

error_file="${RUNNER_TEMP:-/tmp}/aws-inventory-error.txt"
if aws rds describe-db-instances --db-instance-identifier workshop-db >/dev/null 2>"${error_file}"; then
  aws_db=1
elif grep -q 'DBInstanceNotFound' "${error_file}"; then
  aws_db=0
else
  echo "::error::Falha ao inventariar a instancia RDS."
  exit 1
fi

if aws rds describe-db-subnet-groups --db-subnet-group-name workshop-db-subnets >/dev/null 2>"${error_file}"; then
  aws_subnets=1
elif grep -q 'DBSubnetGroupNotFound' "${error_file}"; then
  aws_subnets=0
else
  echo "::error::Falha ao inventariar o DB subnet group."
  exit 1
fi

expected_vpc_id="$(printf 'local.vpc_id\n' | terraform console -no-color | tail -n 1 | tr -d '"\r')"
[[ "${expected_vpc_id}" =~ ^vpc-[0-9a-f]+$ ]] || {
  echo "::error::Contrato do cluster nao forneceu VPC valida."
  exit 1
}

# A existencia e determinada somente pela chave natural VPC + group-name. A tag
# e uma propriedade esperada, validada depois, nunca parte do filtro de existencia.
sg_json="$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=${expected_vpc_id}" 'Name=group-name,Values=workshop-db-sg' \
  --output json)"
sg_count="$(jq '.SecurityGroups | length' <<<"${sg_json}")"
[[ "${sg_count}" =~ ^[0-9]+$ ]] && (( sg_count <= 1 )) || {
  echo "::error::Mais de um SG workshop-db-sg foi encontrado na VPC esperada."
  exit 1
}

aws_sg=0
if (( sg_count == 1 )); then
  aws_sg=1
  project_tag="$(jq -r '.SecurityGroups[0].Tags // [] | map(select(.Key == "Project")) | first | .Value // ""' <<<"${sg_json}")"
  [[ "${project_tag}" == "workshop" ]] || {
    echo "::error::O SG workshop-db-sg existe, mas a tag Project nao e workshop. Reconcilie a tag e o ownership antes de continuar."
    exit 1
  }
fi

aws_signature="${aws_db}${aws_subnets}${aws_sg}"
state_signature="${state_db}${state_subnets}${state_sg}"

if [[ "${aws_signature}" == '000' && "${state_signature}" == '000' && "${require_managed}" != 'true' ]]; then
  echo 'Inventario CREATE confirmado: os tres objetos serao criados.'
elif [[ "${aws_signature}" == '111' && "${state_signature}" == '111' ]]; then
  echo 'Inventario MANAGED confirmado: os tres objetos pertencem a este state.'
elif [[ "${require_managed}" == 'true' ]]; then
  echo "::error::Destroy exige os tres objetos presentes na AWS e no state."
  exit 1
else
  echo "::error::AWS e state divergem ou a topologia esta parcial. Importe/reconcilie antes de continuar."
  exit 1
fi

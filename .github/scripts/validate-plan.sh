#!/usr/bin/env bash
set -Eeuo pipefail

plan_file="${1:?Informe o arquivo de plan}"
operation="${2:-apply}"
[[ "${operation}" == 'apply' || "${operation}" == 'destroy' ]] || {
  echo "::error::Operacao de validacao desconhecida: ${operation}."
  exit 1
}

plan_json="${RUNNER_TEMP:-/tmp}/database-${operation}-plan.json"
trap 'rm -f "${plan_json}"' EXIT
terraform show -json "${plan_file}" >"${plan_json}"

expected_client_sg="$(printf 'local.db_client_sg_id\n' | terraform console -no-color | tail -n 1 | tr -d '"\r')"
[[ "${expected_client_sg}" =~ ^sg-[0-9a-f]+$ ]] || {
  echo "::error::Contrato do cluster nao forneceu db_client_sg_id valido."
  exit 1
}

if [[ "${operation}" == 'destroy' ]]; then
  jq -e '
    ([(.resource_changes // [])[] | select(.mode == "managed") | .address] | sort)
      == ["aws_db_instance.postgres", "aws_db_subnet_group.this", "aws_security_group.db"]
    and
    ([.resource_changes[] | select(.mode == "managed")
      | (.change.actions | index("delete")) != null] | all)
  ' "${plan_json}" >/dev/null || {
    echo "::error::Destroy deve remover exatamente os tres enderecos permitidos."
    exit 1
  }
  echo 'Destroy validado: somente os tres enderecos do state database.'
  exit 0
fi

# planned_values inclui recursos sem mudanca; por isso impede que um recurso extra,
# inclusive de um tipo permitido, se esconda fora de resource_changes.
jq -e '
  ([.planned_values.root_module | .. | objects | (.resources? // empty) | .[]
    | select(.mode == "managed") | .address] | sort)
    == ["aws_db_instance.postgres", "aws_db_subnet_group.this", "aws_security_group.db"]
  and
  ([.resource_changes[]? | select(.mode == "managed") | .address
    | select(. != "aws_db_instance.postgres"
      and . != "aws_db_subnet_group.this"
      and . != "aws_security_group.db")] | length == 0)
  and
  ([.resource_changes[]? | select(.mode == "managed")
    | select((.change.actions | index("delete")) != null)] | length == 0)
' "${plan_json}" >/dev/null || {
  echo "::error::Plan deve conter somente os tres enderecos permitidos e nenhuma delecao/replacement."
  exit 1
}

jq -e '
  [.planned_values.root_module.resources[]? | select(.address == "aws_db_instance.postgres")][0] as $rds
  | $rds.values.publicly_accessible == false
    and $rds.values.storage_encrypted == true
    and $rds.values.db_subnet_group_name == "workshop-db-subnets"
' "${plan_json}" >/dev/null || {
  echo "::error::RDS planejado deve ser privado, criptografado e usar workshop-db-subnets."
  exit 1
}

jq -e --arg client_sg "${expected_client_sg}" '
  [.planned_values.root_module.resources[]? | select(.address == "aws_security_group.db")][0] as $sg
  | ($sg.values.ingress | length) == 1
    and ($sg.values.ingress[0].protocol == "tcp")
    and ($sg.values.ingress[0].from_port == 5432)
    and ($sg.values.ingress[0].to_port == 5432)
    and (($sg.values.ingress[0].cidr_blocks // []) | length) == 0
    and (($sg.values.ingress[0].ipv6_cidr_blocks // []) | length) == 0
    and (($sg.values.ingress[0].prefix_list_ids // []) | length) == 0
    and (($sg.values.ingress[0].security_groups // []) == [$client_sg])
' "${plan_json}" >/dev/null || {
  echo "::error::SG planejado deve ter unico ingress TCP/5432 exatamente de db_client_sg_id, sem CIDRs ou prefix lists."
  exit 1
}

echo 'Plan validado: fronteira, RDS e origem exata do SG confirmados.'

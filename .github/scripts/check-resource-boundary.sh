#!/usr/bin/env bash
set -Eeuo pipefail

expected=$'aws_db_instance.postgres\naws_db_subnet_group.this\naws_security_group.db'
declared="$(perl -0777 -ne 'while (/resource\s+"([^"]+)"\s+"([^"]+)"/g) { print "$1.$2\n" }' ./*.tf | sort -u)"

[[ "${declared}" == "${expected}" ]] || {
  echo "::error::A configuracao deve declarar exatamente os tres recursos permitidos."
  echo 'Esperado:'
  printf '%s\n' "${expected}"
  echo 'Encontrado:'
  printf '%s\n' "${declared}"
  exit 1
}

echo 'Fronteira estatica validada: exatamente tres enderecos gerenciados.'

#!/usr/bin/env bash
set -Eeuo pipefail

state_file="$(mktemp "${RUNNER_TEMP:-/tmp}/cluster-state-test.XXXXXX.json")"
trap 'rm -f "${state_file}"' EXIT

cat >"${state_file}" <<'JSON'
{
  "outputs": {
    "vpc_id": {"value": "vpc-06b5e9b7a9c84322d", "type": "string"},
    "db_client_sg_id": {"value": "sg-0123456789abcdef0", "type": "string"}
  }
}
JSON

read_output() {
  CLUSTER_STATE_FILE="${state_file}" bash .github/scripts/read-cluster-output.sh "$1"
}

[[ "$(read_output vpc_id)" == 'vpc-06b5e9b7a9c84322d' ]]
[[ "$(read_output db_client_sg_id)" == 'sg-0123456789abcdef0' ]]

if read_output output_inexistente >/dev/null 2>&1; then
  echo 'O helper deveria rejeitar output ausente.' >&2
  exit 1
fi

echo 'Leitura do contrato do cluster validada sem depender do state local de database.'

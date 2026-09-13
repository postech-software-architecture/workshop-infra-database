#!/usr/bin/env bash
set -Eeuo pipefail

output_name="${1:?Informe o nome do output do cluster}"
[[ "${output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
  echo "::error::Nome de output do cluster invalido." >&2
  exit 1
}

state_file="${CLUSTER_STATE_FILE:-}"
remove_state_file=false

cleanup() {
  if [[ "${remove_state_file}" == 'true' ]]; then
    rm -f "${state_file}"
  fi
}
trap cleanup EXIT

if [[ -z "${state_file}" ]]; then
  : "${TF_VAR_cluster_state_bucket:?TF_VAR_cluster_state_bucket nao definido}"
  state_file="$(mktemp "${RUNNER_TEMP:-/tmp}/cluster-state.XXXXXX.json")"
  remove_state_file=true
  aws s3api get-object \
    --bucket "${TF_VAR_cluster_state_bucket}" \
    --key "${CLUSTER_STATE_KEY:-cluster/terraform.tfstate}" \
    "${state_file}" >/dev/null
fi

jq -er --arg output_name "${output_name}" '
  .outputs[$output_name].value
  | select(type == "string" and length > 0)
' "${state_file}" 2>/dev/null || {
  echo "::error::Output ${output_name} ausente ou invalido no state do cluster." >&2
  exit 1
}

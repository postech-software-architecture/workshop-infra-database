#!/usr/bin/env bash
set -Eeuo pipefail

: "${BACKEND_BUCKET:?BACKEND_BUCKET nao definido}"
: "${LOCK_TABLE:?LOCK_TABLE nao definido}"

if [[ -n "${TF_VAR_db_password:-}" ]]; then
  echo "::add-mask::${TF_VAR_db_password}"
fi

aws sts get-caller-identity --query Account --output text >/dev/null
aws s3api head-bucket --bucket "${BACKEND_BUCKET}"

versioning="$(aws s3api get-bucket-versioning \
  --bucket "${BACKEND_BUCKET}" --query Status --output text)"
[[ "${versioning}" == "Enabled" ]] || {
  echo "::error::Versionamento do bucket ${BACKEND_BUCKET} deve estar Enabled."
  exit 1
}

encryption="$(aws s3api get-bucket-encryption \
  --bucket "${BACKEND_BUCKET}" \
  --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' \
  --output text)"
[[ "${encryption}" == "AES256" || "${encryption}" == "aws:kms" ]] || {
  echo "::error::Criptografia default do bucket ${BACKEND_BUCKET} esta ausente ou invalida."
  exit 1
}

read -r block_acls ignore_acls block_policy restrict_buckets < <(
  aws s3api get-public-access-block \
    --bucket "${BACKEND_BUCKET}" \
    --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]' \
    --output text
)
[[ "${block_acls}" == "True" && "${ignore_acls}" == "True" && \
   "${block_policy}" == "True" && "${restrict_buckets}" == "True" ]] || {
  echo "::error::As quatro flags de Public Access Block do backend devem estar true."
  exit 1
}

table_status="$(aws dynamodb describe-table \
  --table-name "${LOCK_TABLE}" --query 'Table.TableStatus' --output text)"
[[ "${table_status}" == "ACTIVE" ]] || {
  echo "::error::A tabela de lock ${LOCK_TABLE} deve estar ACTIVE."
  exit 1
}

echo "Backend validado: versioning, encryption, Public Access Block e lock ativos."

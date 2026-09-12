#!/usr/bin/env bash
set -Eeuo pipefail

aws rds wait db-instance-available --db-instance-identifier workshop-db

expected_client_sg="$(printf 'local.db_client_sg_id\n' | terraform console -no-color | tail -n 1 | tr -d '"\r')"
db_sg_id="$(terraform output -raw db_security_group_id)"
[[ "${expected_client_sg}" =~ ^sg-[0-9a-f]+$ && "${db_sg_id}" =~ ^sg-[0-9a-f]+$ ]] || {
  echo "::error::IDs de security group invalidos no contrato/state."
  exit 1
}

db_json="$(aws rds describe-db-instances --db-instance-identifier workshop-db --output json)"
jq -e --arg db_sg "${db_sg_id}" '
  .DBInstances[0]
  | .PubliclyAccessible == false
    and .StorageEncrypted == true
    and .DBSubnetGroup.DBSubnetGroupName == "workshop-db-subnets"
    and ([.VpcSecurityGroups[].VpcSecurityGroupId] == [$db_sg])
' <<<"${db_json}" >/dev/null || {
  echo "::error::RDS na AWS viola privacidade, criptografia, subnet group ou associacao exclusiva do DB SG."
  exit 1
}

sg_json="$(aws ec2 describe-security-groups --group-ids "${db_sg_id}" --output json)"
jq -e --arg client_sg "${expected_client_sg}" '
  (.SecurityGroups | length) == 1
  and (.SecurityGroups[0].IpPermissions | length) == 1
  and (.SecurityGroups[0].IpPermissions[0] as $rule
    | $rule.IpProtocol == "tcp"
      and $rule.FromPort == 5432
      and $rule.ToPort == 5432
      and (($rule.UserIdGroupPairs // []) | length) == 1
      and $rule.UserIdGroupPairs[0].GroupId == $client_sg
      and (($rule.IpRanges // []) | length) == 0
      and (($rule.Ipv6Ranges // []) | length) == 0
      and (($rule.PrefixListIds // []) | length) == 0)
' <<<"${sg_json}" >/dev/null || {
  echo "::error::DB SG na AWS deve ter unico ingress TCP/5432 da origem db_client_sg_id e zero CIDR/IPv6/prefix-list."
  exit 1
}

echo 'AWS validada: subnet group, DB SG exclusivo e ingress exato confirmados.'

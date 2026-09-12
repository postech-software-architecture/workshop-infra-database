# Outputs consumidos pelo repo serverless (Lambda faz JDBC direto no RDS) e pelas
# pipelines que montam o k8s Secret.
#
# A SENHA NAO ESTA AQUI, de proposito: ela vive em Environment secret, consumida
# igualmente pelo k8s Secret e pela Lambda. Ainda assim, como atributo do RDS, fica
# no state do banco; por isso o backend e criptografado e seu acesso e restrito.

output "db_host" {
  description = "Endpoint (host) do RDS. Consumido por: serverless, k8s Secret."
  value       = aws_db_instance.postgres.address
}

output "db_port" {
  description = "Porta do RDS."
  value       = aws_db_instance.postgres.port
}

output "db_name" {
  description = "Nome do banco."
  value       = aws_db_instance.postgres.db_name
}

output "db_username" {
  description = "Usuario master. A senha vem de Environment secret e nunca e publicada como output."
  value       = aws_db_instance.postgres.username
}

output "db_endpoint" {
  description = "host:port, formato de conveniencia para JDBC."
  value       = aws_db_instance.postgres.endpoint
}

output "db_security_group_id" {
  description = "SG do banco, para diagnostico."
  value       = aws_security_group.db.id
}

output "db_instance_identifier" {
  description = "Identificador da instancia — usado no inventario, eventual import e snapshots."
  value       = aws_db_instance.postgres.identifier
}

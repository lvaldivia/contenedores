output "region" { value = var.region }
output "account_id" { value = var.account_id }
output "profile" { value = var.profile }
output "vpc_id" { value = aws_vpc.lab.id }
output "availability_zones" { value = local.azs }
output "public_subnet_ids" { value = aws_subnet.public[*].id }
output "app_private_subnet_ids" { value = aws_subnet.app[*].id }
output "database_subnet_ids" { value = aws_subnet.database[*].id }
output "ecs_security_group_id" { value = aws_security_group.app["ecs"].id }
output "eks_security_group_id" { value = aws_security_group.app["eks"].id }
output "mysql_security_group_id" { value = aws_security_group.mysql.id }
output "mysql_host" { value = aws_db_instance.mysql.address }
output "mysql_port" { value = aws_db_instance.mysql.port }
output "mysql_database" { value = aws_db_instance.mysql.db_name }
output "mysql_admin_secret_arn" {
  description = "Secret ARN only; password is managed by RDS and is not output."
  value       = aws_db_instance.mysql.master_user_secret[0].secret_arn
}

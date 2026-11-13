variable "eks_auto_node_security_group_id" {
  description = "Actual Auto Mode node SG permitted to reach RDS; clear before deleting the EKS cluster."
  type        = string
  default     = ""
}

resource "aws_vpc_security_group_ingress_rule" "mysql_eks_auto" {
  count                        = var.eks_auto_node_security_group_id != "" ? 1 : 0
  security_group_id            = aws_security_group.mysql.id
  referenced_security_group_id = var.eks_auto_node_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  description                  = "MySQL from contenedores-eks Auto Mode nodes"
}

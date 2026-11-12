terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.71"
    }
  }
}

provider "aws" {
  allowed_account_ids = ["299147769461"]
  region              = var.region
  profile             = var.profile
  default_tags {
    tags = { Project = var.name, Purpose = "laboratorio-contenedores", ManagedBy = "Terraform" }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}
variable "profile" {
  type    = string
  default = "luisvaldivia"
}
variable "name" {
  type    = string
  default = "contenedores-lab"
}
variable "vpc_cidr" {
  type    = string
  default = "10.80.0.0/16"
}

data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

resource "aws_vpc" "lab" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.name}-vpc" }
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "${var.name}-igw" }
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.lab.id
  availability_zone       = local.azs[count.index]
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  map_public_ip_on_launch = false
  tags = {
    Name                     = "${var.name}-public-${count.index + 1}"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "app" {
  count             = 2
  vpc_id            = aws_vpc.lab.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + 1)
  tags = {
    Name                              = "${var.name}-app-private-${count.index + 1}"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

resource "aws_subnet" "database" {
  count             = 2
  vpc_id            = aws_vpc.lab.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 240)
  tags              = { Name = "${var.name}-db-isolated-${count.index + 1}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "${var.name}-public" }
}
resource "aws_route" "internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.lab.id
}
resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.name}-nat" }
}
resource "aws_nat_gateway" "lab" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "${var.name}-nat" }
  depends_on    = [aws_internet_gateway.lab, aws_route.internet]
}
resource "aws_route_table" "app" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "${var.name}-app-private" }
}
resource "aws_route" "nat" {
  route_table_id         = aws_route_table.app.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.lab.id
}
resource "aws_route_table_association" "app" {
  count          = 2
  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.app.id
}
resource "aws_route_table" "database" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "${var.name}-db-isolated" }
}
resource "aws_route_table_association" "database" {
  count          = 2
  subnet_id      = aws_subnet.database[count.index].id
  route_table_id = aws_route_table.database.id
}

# Attach these SGs to ECS task ENIs and EKS worker node ENIs respectively.
# EKS uses the default VPC CNI (no custom networking / pod SGs in this lab).
resource "aws_security_group" "app" {
  for_each    = toset(["ecs", "eks"])
  name_prefix = "${var.name}-${each.key}-"
  description = "Application network identity for ${each.key}; ingress added with application"
  vpc_id      = aws_vpc.lab.id
  tags        = { Name = "${var.name}-${each.key}" }
}
resource "aws_vpc_security_group_egress_rule" "app" {
  for_each          = aws_security_group.app
  security_group_id = each.value.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
resource "aws_security_group" "mysql" {
  name_prefix = "${var.name}-mysql-"
  description = "MySQL only from ECS tasks and EKS nodes"
  vpc_id      = aws_vpc.lab.id
  tags        = { Name = "${var.name}-mysql" }
}
resource "aws_vpc_security_group_ingress_rule" "mysql" {
  for_each                     = aws_security_group.app
  security_group_id            = aws_security_group.mysql.id
  referenced_security_group_id = each.value.id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  description                  = "MySQL from ${each.key}"
}

resource "aws_db_subnet_group" "mysql" {
  name       = "${var.name}-mysql"
  subnet_ids = aws_subnet.database[*].id
  tags       = { Name = "${var.name}-mysql" }
}
resource "aws_db_instance" "mysql" {
  identifier                  = "${var.name}-mysql"
  engine                      = "mysql"
  engine_version              = "8.4.11"
  instance_class              = "db.t4g.micro"
  allocated_storage           = 20
  max_allocated_storage       = 30
  storage_type                = "gp3"
  storage_encrypted           = true
  db_name                     = "contenedores"
  username                    = "labadmin"
  manage_master_user_password = true
  db_subnet_group_name        = aws_db_subnet_group.mysql.name
  vpc_security_group_ids      = [aws_security_group.mysql.id]
  publicly_accessible         = false
  multi_az                    = false
  backup_retention_period     = 1
  auto_minor_version_upgrade  = true
  deletion_protection         = false
  skip_final_snapshot         = true
  delete_automated_backups    = true
  copy_tags_to_snapshot       = true
  tags                        = { Name = "${var.name}-mysql" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${local.env}-eks-igw"
  }
}

resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value.cidr_block
  availability_zone       = each.value.availability_zone
  map_public_ip_on_launch = true

  tags = {
    "Name"                                    = "${local.env}-public-eks-${each.value.availability_zone}"
    "kubernetes.io/role/elb"                  = "1"
    "kubernetes.io/cluster/${local.eks_name}" = "owned"
  }
}

resource "aws_route_table" "public" {
  for_each = local.public_subnets

  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${local.env}-public-eks-${each.value.availability_zone}"
  }
}

resource "aws_route_table_association" "public" {
  for_each = local.public_subnets

  subnet_id      = aws_subnet.public[each.key].id
  route_table_id = aws_route_table.public[each.key].id
}

# resource "aws_security_group" "public" {
#   name   = "${local.env}-public-eks"
#   vpc_id = aws_vpc.this.id

#   tags = {
#     Name = "${local.env}-public-eks"
#   }
# }

# resource "aws_vpc_security_group_ingress_rule" "ssh" {
#   security_group_id = aws_security_group.public.id
#   cidr_ipv4         = "0.0.0.0/0"
#   description       = "Allow SSH"
#   from_port         = 22
#   ip_protocol       = "tcp"
#   to_port           = 22
# }

# resource "aws_vpc_security_group_ingress_rule" "http" {
#   security_group_id = aws_security_group.public.id
#   cidr_ipv4         = "0.0.0.0/0"
#   description       = "Allow HTTP"
#   from_port         = 80
#   ip_protocol       = "tcp"
#   to_port           = 80
# }

# resource "aws_vpc_security_group_ingress_rule" "https" {
#   security_group_id = aws_security_group.public.id
#   cidr_ipv4         = "0.0.0.0/0"
#   description       = "Allow HTTPS"
#   from_port         = 443
#   ip_protocol       = "tcp"
#   to_port           = 443
# }

# resource "aws_vpc_security_group_egress_rule" "public" {
#   security_group_id = aws_security_group.public.id
#   cidr_ipv4         = "0.0.0.0/0"
#   ip_protocol       = "-1"
# }

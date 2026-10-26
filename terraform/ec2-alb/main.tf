# =============================================================
#  ARTEX 検証ラボ Phase1  main.tf  (EC2版 / Fargate枠を回避)
#  Internet -> ALB -> EC2(t3.small, Docker) -> OWASP Juice Shop
#  + CloudWatch Logs / VPC Flow Logs / ALB Access Logs / CloudTrail
#
#  使い方:
#    1) 旧(Fargate版)環境を消す:  terraform destroy   (yes)
#    2) このファイルで main.tf を置き換える
#    3) 変数 my_ip_cidr / artex_ip_cidr を自分のIP/32 に（region は東京ならそのまま）
#    4) terraform init  ->  terraform plan  ->  terraform apply   (yes)
#    5) 出力 app_url をブラウザで開く（起動に数分。EC2起動+docker pull待ち）
#    6) 使わない時: EC2停止  または  terraform destroy
# =============================================================

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region  = var.region
  profile = "artex-lab"
}

# ------------------------- variables -------------------------
variable "region" { default = "ap-northeast-1" }
variable "project" { default = "artex-lab" }
variable "my_ip_cidr" { default = "0.0.0.0/32" }    # ←★自分のグローバルIP/32（必須）
variable "artex_ip_cidr" { default = "0.0.0.0/32" } # ←★ARTEX実行元IP/32（手元PCなら同じ値）
variable "instance_type" { default = "t3.small" }   # 2vCPU/2GB。無料枠狙いなら t3.micro/t2.micro(1GB・やや窮屈)

data "aws_availability_zones" "available" { state = "available" }
data "aws_caller_identity" "me" {}
data "aws_elb_service_account" "alb" {}

# 最新の Amazon Linux 2023 AMI を自動取得
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# ------------------------- network ---------------------------
resource "aws_vpc" "main" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_hostnames = true
  tags                 = { Name = "${var.project}-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project}-igw" }
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.project}-public-${count.index}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project}-public-rt" }
}

resource "aws_route" "inet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# --- VPC Flow Logs -> CloudWatch Logs ---
resource "aws_cloudwatch_log_group" "flow" {
  name              = "/${var.project}/vpc-flow-logs"
  retention_in_days = 14
}

resource "aws_iam_role" "flow" {
  name = "${var.project}-flow-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "vpc-flow-logs.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "flow" {
  role = aws_iam_role.flow.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect   = "Allow",
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogGroups", "logs:DescribeLogStreams"],
      Resource = "*"
    }]
  })
}

resource "aws_flow_log" "vpc" {
  vpc_id               = aws_vpc.main.id
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flow.arn
  iam_role_arn         = aws_iam_role.flow.arn
}

# ------------------------- logging (S3 + CloudTrail) ----------
resource "aws_s3_bucket" "alb_logs" {
  bucket        = "${var.project}-alb-logs-${data.aws_caller_identity.me.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { AWS = data.aws_elb_service_account.alb.arn },
      Action    = "s3:PutObject",
      Resource  = "${aws_s3_bucket.alb_logs.arn}/alb/*"
    }]
  })
}

resource "aws_s3_bucket" "trail" {
  bucket        = "${var.project}-cloudtrail-${data.aws_caller_identity.me.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_policy" "trail" {
  bucket = aws_s3_bucket.trail.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid       = "AclCheck",
        Effect    = "Allow",
        Principal = { Service = "cloudtrail.amazonaws.com" },
        Action    = "s3:GetBucketAcl",
        Resource  = aws_s3_bucket.trail.arn
      },
      {
        Sid       = "Write",
        Effect    = "Allow",
        Principal = { Service = "cloudtrail.amazonaws.com" },
        Action    = "s3:PutObject",
        Resource  = "${aws_s3_bucket.trail.arn}/AWSLogs/${data.aws_caller_identity.me.account_id}/*",
        Condition = { StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" } }
      }
    ]
  })
}

resource "aws_cloudtrail" "main" {
  name                          = "${var.project}-trail"
  s3_bucket_name                = aws_s3_bucket.trail.id
  include_global_service_events = true
  is_multi_region_trail         = false
  depends_on                    = [aws_s3_bucket_policy.trail]
}

# ------------------------- app log group ---------------------
resource "aws_cloudwatch_log_group" "app" {
  name              = "/${var.project}/juice-shop"
  retention_in_days = 14
}

# ------------------------- IAM for EC2 -----------------------
resource "aws_iam_role" "ec2" {
  name = "${var.project}-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "ec2.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })
}

# dockerのawslogsドライバがCloudWatchへ書けるように
resource "aws_iam_role_policy" "ec2_logs" {
  role = aws_iam_role.ec2.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect   = "Allow",
      Action   = ["logs:CreateLogStream", "logs:CreateLogGroup", "logs:PutLogEvents", "logs:DescribeLogStreams"],
      Resource = "*"
    }]
  })
}

# SSM Session Manager で SSH無しでも接続可能に（任意・デバッグ用）
resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project}-ec2-profile"
  role = aws_iam_role.ec2.name
}

# ------------------------- ALB -------------------------------
resource "aws_security_group" "alb" {
  name   = "${var.project}-alb-sg"
  vpc_id = aws_vpc.main.id
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr, var.artex_ip_cidr] # 全公開せず絞る
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "app" {
  name               = "${var.project}-alb"
  load_balancer_type = "application"
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb.id]
  access_logs {
    bucket  = aws_s3_bucket.alb_logs.id
    prefix  = "alb"
    enabled = true
  }
  depends_on = [aws_s3_bucket_policy.alb_logs]
}

resource "aws_lb_target_group" "app" {
  name        = "${var.project}-tg"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"
  health_check {
    path                = "/"
    matcher             = "200"
    healthy_threshold   = 2
    unhealthy_threshold = 5
    interval            = 30
    timeout             = 10
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ------------------------- EC2 (Docker + Juice Shop) ---------
resource "aws_security_group" "ec2" {
  name   = "${var.project}-ec2-sg"
  vpc_id = aws_vpc.main.id
  # Juice Shop(3000) は ALB からのみ
  ingress {
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "app" {
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public[0].id
  vpc_security_group_ids      = [aws_security_group.ec2.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  associate_public_ip_address = true

  user_data = <<-EOF
    #!/bin/bash
    set -eux
    dnf update -y
    dnf install -y docker
    systemctl enable --now docker
    # 起動後、Juice Shop を docker で起動。ログは awslogs ドライバで CloudWatch へ
    docker run -d --restart always -p 3000:3000 \
      --log-driver=awslogs \
      --log-opt awslogs-region=${var.region} \
      --log-opt awslogs-group=/${var.project}/juice-shop \
      --log-opt awslogs-create-group=true \
      bkimminich/juice-shop:latest
  EOF

  tags       = { Name = "${var.project}-juice" }
  depends_on = [aws_iam_role_policy.ec2_logs]
}

resource "aws_lb_target_group_attachment" "app" {
  target_group_arn = aws_lb_target_group.app.arn
  target_id        = aws_instance.app.id
  port             = 3000
}

# ------------------------- outputs ---------------------------
output "app_url" {
  value = "http://${aws_lb.app.dns_name}/"
}
output "ec2_instance_id" {
  value = aws_instance.app.id
}
output "account_id" {
  value = data.aws_caller_identity.me.account_id
}

# =============================================================
#  ARTEX 検証ラボ Phase1  main.tf  (1ファイル完成版)
#  ALB -> ECS(Fargate) -> OWASP Juice Shop
#  + CloudWatch Logs / VPC Flow Logs / ALB Access Logs / CloudTrail
#
#  使い方:
#    1) 下の variables の default 3つ（my_ip_cidr / artex_ip_cidr / region）を自分の値に。
#       自分のIP: PowerShellで  curl https://checkip.amazonaws.com   の結果 + "/32"
#    2) terraform init  ->  terraform plan  ->  terraform apply   (yes)
#    3) 出力 app_url をブラウザで開く
#    4) 終わったら terraform destroy  (yes)   ※課金停止
# =============================================================

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region  = var.region
  profile = "artex-lab" # phase0 で作成した構築用プロファイル（admin回避）
}

# ------------------------- variables -------------------------
variable "region" { default = "ap-northeast-1" } # ←使うリージョン
variable "project" { default = "artex-lab" }
variable "my_ip_cidr" { default = "0.0.0.0/32" }    # ←★自分のグローバルIP/32 に変更（必須）
variable "artex_ip_cidr" { default = "0.0.0.0/32" } # ←★ARTEX実行元IP/32（手元PCなら上と同じ値）
variable "juice_image" { default = "bkimminich/juice-shop:latest" }

data "aws_availability_zones" "available" { state = "available" }
data "aws_caller_identity" "me" {}
data "aws_elb_service_account" "alb" {}

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
  target_type = "ip"
  health_check {
    path    = "/"
    matcher = "200"
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

# ------------------------- ECS Fargate -----------------------
resource "aws_ecs_cluster" "main" {
  name = "${var.project}-cluster"
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/${var.project}/juice-shop"
  retention_in_days = 14
}

resource "aws_iam_role" "exec" {
  name = "${var.project}-ecs-exec"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "ecs-tasks.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "exec" {
  role       = aws_iam_role.exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_ecs_task_definition" "app" {
  family                   = "${var.project}-juice"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.exec.arn
  container_definitions = jsonencode([{
    name         = "juice-shop",
    image        = var.juice_image,
    portMappings = [{ containerPort = 3000 }],
    logConfiguration = {
      logDriver = "awslogs",
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.app.name,
        "awslogs-region"        = var.region,
        "awslogs-stream-prefix" = "juice"
      }
    }
  }])
}

resource "aws_security_group" "ecs" {
  name   = "${var.project}-ecs-sg"
  vpc_id = aws_vpc.main.id
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

resource "aws_ecs_service" "app" {
  name            = "${var.project}-svc"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1 # 使わない時は 0 に（コスト対策）
  launch_type     = "FARGATE"
  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = true
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "juice-shop"
    container_port   = 3000
  }
  depends_on = [aws_lb_listener.http]
}

# ------------------------- outputs ---------------------------
output "app_url" {
  value = "http://${aws_lb.app.dns_name}/"
}
output "account_id" {
  value = data.aws_caller_identity.me.account_id
}

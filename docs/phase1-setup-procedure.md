# Phase1 検証環境構築手順（ドラフト）

> 目的: ARTEX の実行対象（OWASP Juice Shop）を ALB + ECS(Fargate) 上に立て、
> 攻撃ログを収集できる状態（CloudWatch Logs / ALB Access Logs / VPC Flow Logs / CloudTrail）を作る。
> **帰宅後すぐ着手できるよう、Terraform 一式を骨子として用意。** 不明点はプレースホルダ `<< >>` で明示。
> 最終更新: 2026-10-26 / ステータス: ドラフト（レビュー前）

---

## 0. 前提・方針

- **リージョン**: `<<ap-northeast-1 を想定。確定待ち>>`
- **IaC**: Terraform で構築（再現性＋`terraform destroy` で確実に停止＝コスト対策）。
  - コンソール手動派の場合は §7 に手順対応表。
- **公開範囲（重要）**: ALB はインターネット公開になるが、Juice Shop は脆弱アプリのため
  **Security Group の inbound を自宅/作業元のグローバル IP に限定**することを強く推奨。
  ARTEX の実行元 IP も許可リストに入れる。`<<許可IPを確認>>`
- **ARTEX 実行元**: `<<手元PCか、AWS内の踏み台EC2か未確認>>`。AWS内から実行する場合は
  VPC Flow Logs / ALB ログでの見え方が変わる点に注意（§Phase3で扱う）。
- **コスト対策**: 使わない時間は ECS サービスの desired count を 0 に。`terraform destroy` で全削除可。

### 事前に必要なもの
- [ ] **構築用IAM権限を admin から切り出し済み** → `phase0-iam-setup.md` を先に実施（admin常用を避ける）
- [ ] AWS CLI 設定済み（builderプロファイル `artex-lab` を使用）: `aws sts get-caller-identity --profile artex-lab`
- [ ] Terraform v1.5+ : `terraform version`
- [ ] 作業元グローバルIP: `curl -s https://checkip.amazonaws.com`

---

## 1. ディレクトリ構成（Terraform）

```text
artex-lab/
├── provider.tf
├── variables.tf
├── network.tf        # VPC, Subnet, IGW, Route, VPC Flow Logs
├── logging.tf        # CloudWatch LogGroup, S3(ALBログ/Flowログ/CloudTrail), CloudTrail
├── alb.tf            # ALB, Target Group, Listener, SG
├── ecs.tf            # ECS Cluster, TaskDef(Juice Shop), Service, SG
└── outputs.tf
```

---

## 2. provider / variables

```hcl
# provider.tf
terraform {
  required_version = ">= 1.5"
  required_providers { aws = { source = "hashicorp/aws", version = "~> 5.0" } }
}
provider "aws" { region = var.region }

# variables.tf
variable "region"       { default = "ap-northeast-1" }      # << 確認
variable "project"      { default = "artex-lab" }
variable "my_ip_cidr"   { default = "<<x.x.x.x/32>>" }       # << 作業元IP。必ず絞る
variable "artex_ip_cidr"{ default = "<<ARTEX実行元/32 or 同上>>" }
variable "juice_image"  { default = "bkimminich/juice-shop:latest" }
data "aws_availability_zones" "available" { state = "available" }
```

---

## 3. ネットワーク + VPC Flow Logs（network.tf）

```hcl
resource "aws_vpc" "main" {
  cidr_block = "10.20.0.0/16"
  enable_dns_hostnames = true
  tags = { Name = "${var.project}-vpc" }
}
resource "aws_internet_gateway" "igw" { vpc_id = aws_vpc.main.id }

# ALB用パブリックサブネット x2（ALBは2AZ必須）
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
}
resource "aws_route_table" "public" { vpc_id = aws_vpc.main.id }
resource "aws_route" "inet" {
  route_table_id = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id = aws_internet_gateway.igw.id
}
resource "aws_route_table_association" "public" {
  count = 2
  subnet_id = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# --- VPC Flow Logs（CloudWatch Logsへ。Phase3で見る） ---
resource "aws_cloudwatch_log_group" "flow" {
  name = "/${var.project}/vpc-flow-logs"
  retention_in_days = 14
}
resource "aws_iam_role" "flow" {
  name = "${var.project}-flow-role"
  assume_role_policy = jsonencode({ Version="2012-10-17", Statement=[{
    Effect="Allow", Principal={Service="vpc-flow-logs.amazonaws.com"}, Action="sts:AssumeRole"}]})
}
resource "aws_iam_role_policy" "flow" {
  role = aws_iam_role.flow.id
  policy = jsonencode({ Version="2012-10-17", Statement=[{
    Effect="Allow",
    Action=["logs:CreateLogStream","logs:PutLogEvents","logs:DescribeLogGroups","logs:DescribeLogStreams"],
    Resource="*"}]})
}
resource "aws_flow_log" "vpc" {
  vpc_id               = aws_vpc.main.id
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flow.arn
  iam_role_arn         = aws_iam_role.flow.arn
}
```

> メモ: Flow Logs は ALL（accept+reject）で取得し、探索時のリジェクト通信も見えるようにする。

---

## 4. ロギング: ALBアクセスログ / CloudTrail（logging.tf）

```hcl
data "aws_caller_identity" "me" {}
data "aws_elb_service_account" "alb" {}  # ALBログ書込み用のAWSアカウント

# ALBアクセスログ用S3
resource "aws_s3_bucket" "alb_logs" {
  bucket = "${var.project}-alb-logs-${data.aws_caller_identity.me.account_id}"
  force_destroy = true
}
resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  policy = jsonencode({ Version="2012-10-17", Statement=[{
    Effect="Allow",
    Principal={AWS=data.aws_elb_service_account.alb.arn},
    Action="s3:PutObject",
    Resource="${aws_s3_bucket.alb_logs.arn}/alb/*"}]})
}

# CloudTrail（管理イベント。API操作の記録）
resource "aws_s3_bucket" "trail" {
  bucket = "${var.project}-cloudtrail-${data.aws_caller_identity.me.account_id}"
  force_destroy = true
}
resource "aws_s3_bucket_policy" "trail" {
  bucket = aws_s3_bucket.trail.id
  policy = jsonencode({ Version="2012-10-17", Statement=[
    { Sid="AclCheck", Effect="Allow", Principal={Service="cloudtrail.amazonaws.com"},
      Action="s3:GetBucketAcl", Resource=aws_s3_bucket.trail.arn },
    { Sid="Write", Effect="Allow", Principal={Service="cloudtrail.amazonaws.com"},
      Action="s3:PutObject", Resource="${aws_s3_bucket.trail.arn}/AWSLogs/${data.aws_caller_identity.me.account_id}/*",
      Condition={StringEquals={"s3:x-amz-acl"="bucket-owner-full-control"}} }]})
}
resource "aws_cloudtrail" "main" {
  name = "${var.project}-trail"
  s3_bucket_name = aws_s3_bucket.trail.id
  include_global_service_events = true
  is_multi_region_trail = false
  depends_on = [aws_s3_bucket_policy.trail]
}
```

> 注: Juice Shop への Web 攻撃は **CloudTrail には出ない**（CloudTrail は AWS API 操作の記録）。
> Web レイヤの攻撃は **ALB Access Logs / ECS(アプリ)ログ** に出る。この住み分けは Phase3 の重要ポイント。

---

## 5. ALB（alb.tf）

```hcl
resource "aws_security_group" "alb" {
  name = "${var.project}-alb-sg"
  vpc_id = aws_vpc.main.id
  ingress { from_port=80 to_port=80 protocol="tcp"
            cidr_blocks=[var.my_ip_cidr, var.artex_ip_cidr] }   # ← 全公開せず絞る
  egress  { from_port=0 to_port=0 protocol="-1" cidr_blocks=["0.0.0.0/0"] }
}
resource "aws_lb" "app" {
  name = "${var.project}-alb"
  load_balancer_type = "application"
  subnets = aws_subnet.public[*].id
  security_groups = [aws_security_group.alb.id]
  access_logs { bucket = aws_s3_bucket.alb_logs.id, prefix = "alb", enabled = true }
}
resource "aws_lb_target_group" "app" {
  name = "${var.project}-tg"
  port = 3000           # Juice Shop は 3000 番
  protocol = "HTTP"
  vpc_id = aws_vpc.main.id
  target_type = "ip"    # Fargate は ip ターゲット
  health_check { path = "/" matcher = "200" }
}
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port = 80 protocol = "HTTP"
  default_action { type = "forward" target_group_arn = aws_lb_target_group.app.arn }
}
```

---

## 6. ECS Fargate + Juice Shop（ecs.tf）

```hcl
resource "aws_ecs_cluster" "main" { name = "${var.project}-cluster" }

resource "aws_cloudwatch_log_group" "app" {
  name = "/${var.project}/juice-shop"
  retention_in_days = 14
}
resource "aws_iam_role" "exec" {
  name = "${var.project}-ecs-exec"
  assume_role_policy = jsonencode({ Version="2012-10-17", Statement=[{
    Effect="Allow", Principal={Service="ecs-tasks.amazonaws.com"}, Action="sts:AssumeRole"}]})
}
resource "aws_iam_role_policy_attachment" "exec" {
  role = aws_iam_role.exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
resource "aws_ecs_task_definition" "app" {
  family = "${var.project}-juice"
  requires_compatibilities = ["FARGATE"]
  network_mode = "awsvpc"
  cpu = "512" memory = "1024"
  execution_role_arn = aws_iam_role.exec.arn
  container_definitions = jsonencode([{
    name = "juice-shop", image = var.juice_image,
    portMappings = [{ containerPort = 3000 }],
    logConfiguration = { logDriver="awslogs", options={
      "awslogs-group"=aws_cloudwatch_log_group.app.name,
      "awslogs-region"=var.region, "awslogs-stream-prefix"="juice" }}
  }])
}
resource "aws_security_group" "ecs" {
  name = "${var.project}-ecs-sg"
  vpc_id = aws_vpc.main.id
  ingress { from_port=3000 to_port=3000 protocol="tcp" security_groups=[aws_security_group.alb.id] }
  egress  { from_port=0 to_port=0 protocol="-1" cidr_blocks=["0.0.0.0/0"] }
}
resource "aws_ecs_service" "app" {
  name = "${var.project}-svc"
  cluster = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count = 1          # ← 使わない時は 0 に（コスト対策）
  launch_type = "FARGATE"
  network_configuration {
    subnets = aws_subnet.public[*].id
    security_groups = [aws_security_group.ecs.id]
    assign_public_ip = true   # パブリックサブネット運用（NAT GW不要でコスト減）
  }
  load_balancer { target_group_arn = aws_lb_target_group.app.arn
                  container_name = "juice-shop" container_port = 3000 }
  depends_on = [aws_lb_listener.http]
}

# outputs.tf
output "app_url" { value = "http://${aws_lb.app.dns_name}/" }
```

---

## 7. 構築・確認・停止コマンド

```bash
# 構築
terraform init
terraform plan
terraform apply            # 完了後、出力の app_url にブラウザアクセス → Juice Shop 表示を確認

# 動作確認
curl -s $(terraform output -raw app_url) | head

# コスト対策: 一時停止（環境は残す / 課金ほぼ停止）
#   ecs.tf の desired_count を 0 にして apply、または：
aws ecs update-service --cluster artex-lab-cluster --service artex-lab-svc --desired-count 0

# 完全削除
terraform destroy
```

---

## 8. Phase1 完了チェックリスト

- [ ] `app_url` で Juice Shop トップが表示される
- [ ] CloudWatch Logs `/artex-lab/juice-shop` にアプリログが流れている
- [ ] CloudWatch Logs `/artex-lab/vpc-flow-logs` に Flow Logs が出ている
- [ ] S3 `*-alb-logs` に ALB アクセスログが（数分後に）出力される
- [ ] CloudTrail `artex-lab-trail` のイベント履歴が CloudTrail コンソールで見える
- [ ] ALB の SG が作業元/ARTEX IP に絞られている（全公開になっていない）

---

## 9. 次フェーズへの申し送り

- **Phase2(ARTEX実行)**: ARTEX 本体の入手元・導入形態・使用LLMが未確定のため別ファイルで骨子待ち。
  → `phase2-artex-run.md`（作成予定、要コンテキスト）
- **Phase3(ログ分析)**: 攻撃がどのログのどこに出るかの対応表を用意予定。
  → `phase3-log-analysis.md`
- **Phase4(WAF)**: `aws_wafv2_web_acl` を ALB に関連付け、マネージドルール（Core/SQLi 等）で
  Juice Shop への攻撃の検知・ブロックを比較。

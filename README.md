# aws-artex

AIペンテストツール **ARTEX** を自作のAWS検証環境で動かし、**攻撃者視点**と **AWS上での検知・監視（防御側の知見）** を学ぶための検証ラボ一式です。

> 正当な自己所有・検証用環境に対する、検証／防御学習目的のリポジトリです。攻撃対象は意図的に脆弱な学習用アプリ **OWASP Juice Shop** のみで、第三者環境は対象外です。

---

## 目的・学習したいこと

- AIペンテスターがどのように探索するか
- 攻撃や探索が AWS ログにどう記録されるか（CloudWatch Logs / VPC Flow Logs / ALB Access Logs / CloudTrail）
- WAF による検知・防御の仕組み（Phase4）
- 攻撃発生時に何を確認すべきか（初動調査の観点）

詳細な学習計画は [`docs/context.md`](docs/context.md) を参照。

---

## 構成

```text
Internet
    │  (Security Group で 自分/ARTEX実行元の IP /32 のみ許可)
    ▼
 [ALB]          ← 検証本番で追加（ALB Access Logs を取得）
    │
    ▼
 EC2 (t3.small, Docker)
    │
    ▼
 OWASP Juice Shop

＋ CloudWatch Logs（アプリ）
＋ VPC Flow Logs
＋ CloudTrail
＋ (Phase4) AWS WAF
```

現状はコスト最小化のため **ALB 無しの EC2 直構成** を採用。検証本番時に ALB あり構成へ立て直す方針。

---

## ディレクトリ

```text
terraform/
  ec2-noalb/   現行採用。Internet -> EC2(80) -> Juice Shop。ALB無し＝コスト最小
  ec2-alb/     参考。Internet -> ALB -> EC2 -> Juice Shop（ALB Access Logs あり。WAF検証はこちら）
  fargate/     当初案。ECS(Fargate)構成。※下記の経緯により現在は保留
docs/
  context.md               学習計画マスター（Phase1〜4 / コスト / 記事候補）
  phase0-iam-setup.md      構築用IAM権限の切り出し（admin常用回避）
  phase1-setup-procedure.md Phase1構築手順（Fargate版の詳細解説）
  terraform-quickstart.md  Terraform未経験者向けクイックスタート
  phase3-log-analysis.md   ログ分析リファレンス（どの攻撃がどのログに出るか）
  zenn-capture-checklist.md Zenn記事用の撮影・ログ取得チェックリスト（マスキング注意つき）
  zenn-article-outline.md  Zenn記事の構成案
```

---

## 前提

- AWS CLI 設定済み（構築用プロファイル `artex-lab`。`docs/phase0-iam-setup.md` 参照）
- Terraform v1.5+
- リージョン: `ap-northeast-1`（東京）想定
- 構築用IAMユーザー `artex-lab-builder`（admin / root は常用しない）

---

## 使い方（現行: ALB無し版）

```bash
cd terraform/ec2-noalb

# main.tf の変数を自分の値に:
#   my_ip_cidr    = "<自分のグローバルIP>/32"   (curl https://checkip.amazonaws.com)
#   artex_ip_cidr = "<ARTEX実行元IP>/32"        (手元PCなら my_ip_cidr と同じ)

terraform init
terraform plan
terraform apply      # yes

# 出力 app_url (http://<EC2のIP>/) をブラウザで開く
# EC2起動 + docker pull で数分かかる。最初つながらなくても1〜3分待って再読込

# 使い終わったら必ず削除（課金停止）
terraform destroy    # yes
```

ALBあり版を使う場合は `terraform/ec2-alb/` で同様に実行（`app_url` は ALB の DNS 名になる）。

---

## コスト注意

- **EC2・ALB はどちらも「起動している時間」で課金**されます（アクセス数ではなく時間課金が主）。
  - ALB: 固定の時間課金（東京で概ね ¥3.6/時）＋ わずかな LCU。24時間稼働で月¥2,000〜3,000目安。
  - EC2 t3.small: 起動中のみ時間課金。
- **使わない時は `terraform destroy`** が最も無駄がない運用。EC2停止だけだとパブリックIPが変わる点に注意。
- LLM API（ARTEX用 Claude/OpenAI）は従量課金（軽い検証 50〜300円/回 目安）。

---

## 構成変更の経緯（Fargateブロック）

当初は ECS(Fargate) で構築し `terraform apply` 自体は成功したが、**Fargate On-Demand vCPU の上限（account blocked）によりタスクを起動できなかった**。上限緩和申請中。これを受けて Fargate 枠に当たらない **EC2 構成へ変更**した。`terraform/fargate/` は記録・参考として残置。

---

## セキュリティ運用メモ

- `main.tf` の `my_ip_cidr` / `artex_ip_cidr` で **アクセス元IPを /32 に限定**（脆弱アプリの保護）。
- **tfstate・アクセスキー・認証情報はコミットしない**（`.gitignore` で除外済み）。
- 構築作業は最小権限の `artex-lab-builder` プロファイルで（`docs/phase0-iam-setup.md`）。

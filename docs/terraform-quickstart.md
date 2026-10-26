# Terraform はじめてガイド（Windows / 本プロジェクト用）

> Terraform 未経験でも、**コードを書かずに**用意済みの設定をそのまま実行して環境を作れます。
> 「作る(apply)」「消す(destroy)」の2つが分かれば十分。最終更新: 2026-10-26

---

## 0. Terraform とは（30秒）

- 「作りたいAWS構成をテキストで書いておくと、その通りに作ってくれる」ツール。
- 今回は構成ファイル（`.tf`）はこちらで用意済み。**あなたは中身を編集して実行するだけ。**
- 利点: **`terraform destroy` 一発で全部消せる**（消し忘れ＝課金事故を防げる＝検証向き）。

---

## 1. インストール（Windows）

PowerShell（管理者）で、パッケージマネージャ chocolatey か winget を使うのが簡単:

```powershell
# winget（Windows標準）
winget install HashiCorp.Terraform

# もしくは choco
choco install terraform
```

手動の場合: https://developer.hashicorp.com/terraform/install から zip をDL → 解凍した `terraform.exe` を PATH の通ったフォルダ（例 `C:\terraform\`）に置く。

確認:
```powershell
terraform version   # Terraform v1.x が表示されればOK
```

---

## 2. ファイルを置く

作業フォルダ（例 `D:\study\aws-artex\`）に、`phase1-setup-procedure.md` に載っている
`.tf` ファイルを作成して貼り付けます。初めてなら **1ファイルにまとめてもOK**:

- `main.tf` を作り、手順書 §2〜§6 のコードブロックを**順番に全部**貼り付け。
  （provider / variables / network / logging / alb / ecs / outputs を1ファイルに連結して可）

> このあと、まとめ済みの `main.tf` が欲しければ言ってください。すぐ作ってお渡しします。

---

## 3. 編集するのは変数だけ（`variables` の既定値）

次の3つだけ自分の値に置き換えます（他はそのままでOK）:

| 変数 | 入れる値 | 確認方法 |
|---|---|---|
| `region` | 使うリージョン（例 `ap-northeast-1`） | 東京ならこのまま |
| `my_ip_cidr` | あなたのグローバルIP + `/32` | `curl https://checkip.amazonaws.com` の結果に `/32` を付ける |
| `artex_ip_cidr` | ARTEX実行元IP + `/32`（手元PCから実行なら `my_ip_cidr` と同じでOK） | 同上 |

さらに、admin回避のため `provider` ブロックに builder プロファイルを指定:
```hcl
provider "aws" {
  region  = var.region
  profile = "artex-lab"   # ← §phase0 で作ったプロファイル
}
```

---

## 4. 実行（基本はこの3コマンド）

作業フォルダで:

```powershell
terraform init     # 初回だけ。AWS用プラグインを取得（数十秒）
terraform plan     # 何が作られるかの"予定表"を表示（まだ作らない。確認用）
terraform apply    # 実際に作る。最後に yes と入力すると構築開始（数分）
```

- `apply` 完了後、`Outputs:` に `app_url = http://...` が出ます。ブラウザで開くと Juice Shop が表示。
- 途中で `AccessDenied` が出たら、IAM権限不足 → `phase0-iam-setup.md` の該当Actionを足す。

---

## 5. 止める・消す（コスト対策／重要）

```powershell
# 一時停止（環境は残す・課金ほぼ止める）: ECSのタスク数を0に
aws ecs update-service --cluster artex-lab-cluster --service artex-lab-svc --desired-count 0 --profile artex-lab

# 完全削除（全リソース削除。検証終わりはこれ）
terraform destroy   # yes と入力
```

> `destroy` を実行すれば課金対象はほぼ残りません。S3にログが残る場合は手順書の `force_destroy=true` で一緒に消えます。

---

## 6. つまずきやすいポイント

- `terraform` が見つからない → PATH設定後、PowerShellを開き直す。
- `profile (artex-lab) could not be found` → `aws configure --profile artex-lab` を先に実行（§phase0）。
- `apply` でIAMエラー → Option A の `iam-limited` ポリシーが付いているか確認。
- 2回目以降の `init` は不要（フォルダを変えた時だけ）。

---

## 7. 「Terraformは使いたくない」場合

マネジメントコンソール（GUI）だけで作る手順も用意できます。ただし今回の構成は
VPC/サブネット/ルート/ALB/ターゲットグループ/ECSタスク定義/IAMロール/S3バケットポリシー…と
**クリック工程がかなり多く、初心者にはTerraformより大変**です。
学習として「各リソースを手で作って理解したい」なら価値はあるので、希望があれば
`phase1-console-setup.md` として作成します。

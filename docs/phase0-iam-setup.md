# Phase0 構築用IAM権限の切り出し手順（ドラフト）

> 目的: admin（AdministratorAccess / root）常用をやめ、**Phase1 の環境構築に必要な分だけ**を持つ
> 専用 IAM ユーザー（またはロール）を用意する。AWSマネジメントコンソールでの操作ステップで記載。
> 最終更新: 2026-10-26 / ステータス: ドラフト

---

## 0. 考え方（現実的な落とし所）

厳密な最小権限はメンテが重いので、検証用途では次の3段階で選ぶ。**推奨は Option A。**

| | 内容 | 向き |
|---|---|---|
| **Option A（推奨）** | `PowerUserAccess`（AWS管理ポリシー）＋ **IAMを一部だけ許可する自作ポリシー** | 検証を止めずに admin を避ける現実解 |
| Option B（厳格） | 使用サービスだけに絞った**自作ポリシー1本** | 最小権限を学びたい／記事ネタにするなら |
| ❌ 避ける | `AdministratorAccess` や root を常用 | — |

- なぜ PowerUser 単体ではダメか: `PowerUserAccess` は **IAM操作を含まない**。
  今回の Terraform は ECS実行ロール・VPC Flow Logs 用ロールを**作る**ので、IAM権限が少し要る。
  → Option A は「PowerUser ＋ プロジェクト用ロールに限定した IAM 権限」で補う。

> いずれも **root は使わない / MFA を有効化 / アクセスキーは専用ユーザーのものを使う**。

---

## 1. 共通: 専用IAMユーザーを作る（コンソール）

1. マネジメントコンソールに **IAM管理者（or root＋MFA）** でログイン。
2. 上部検索で **IAM** → 左メニュー **ユーザー** → **ユーザーの作成**。
3. ユーザー名: `artex-lab-builder`。
   - **「AWSマネジメントコンソールへのユーザーアクセスを提供する」は原則チェック不要**（オフのまま）。
     このユーザーは Terraform/CLI 用でアクセスキーで使うため、コンソールへのログイン（パスワード）は不要。
     コンソール作業は既存の admin/root（＋MFA）で行う前提。
   - 例外: この限定ユーザーでコンソールもクリック操作したい場合のみチェックし、パスワードを設定。
   - → 次へ。
4. 許可の設定: **ポリシーを直接アタッチする**（グループ運用なら後述）。
   - Option A: `PowerUserAccess` にチェック（この後 §3 の自作ポリシーも追加）。
   - Option B: §4 で作る自作ポリシーをアタッチ（ここでは一旦スキップして作成後に付与）。
5. 確認 → **ユーザーの作成**。
6. 作成後、ユーザー詳細 → **セキュリティ認証情報**:
   - **多要素認証(MFA)** を割り当て。
   - CLI/Terraform 用に **アクセスキーを作成**（用途: 「CLI」）。
     → 表示されるキーを `aws configure --profile artex-lab` で設定（キーはこの時だけ表示。保管注意）。

> 補足（より良い運用）: 常用アクセスキーを避けたい場合は、権限はロールに付け、
> `artex-lab-builder` には **AssumeRole だけ**許可して `aws sts assume-role` or プロファイルで引き受ける構成も可。
> 検証段階では上記ユーザー＋MFAで十分。

---

## 2. （任意）グループで管理する場合

ユーザーに直接ではなくグループ経由が望ましい:
1. IAM → **ユーザーグループ** → **グループの作成** → 名前 `artex-lab-builders`。
2. ポリシー（Option A の2本 or Option B の1本）をグループにアタッチ。
3. `artex-lab-builder` をこのグループに追加。

---

## 3. Option A: IAMを限定許可する自作ポリシー

PowerUserAccess に加えて、**プロジェクト用ロール(`artex-lab-*`)の作成・PassRole だけ**を許可する。

### 作成手順（コンソール）
1. IAM → **ポリシー** → **ポリシーの作成** → **JSON** タブ。
2. 下記を貼り付け（`<<ACCOUNT_ID>>` を自分の12桁アカウントIDに置換）→ 次へ。
3. ポリシー名: `artex-lab-iam-limited` → 作成。
4. §1/§2 で `artex-lab-builder`（またはグループ）に **PowerUserAccess と本ポリシーの2本**をアタッチ。

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ManageProjectRolesOnly",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:TagRole", "iam:UntagRole",
        "iam:AttachRolePolicy", "iam:DetachRolePolicy",
        "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy",
        "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole"
      ],
      "Resource": "arn:aws:iam::<<ACCOUNT_ID>>:role/artex-lab-*"
    },
    {
      "Sid": "PassProjectRolesToServices",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::<<ACCOUNT_ID>>:role/artex-lab-*",
      "Condition": {
        "StringEquals": { "iam:PassedToService":
          ["ecs-tasks.amazonaws.com", "vpc-flow-logs.amazonaws.com"] }
      }
    },
    {
      "Sid": "ReadOnlyIamForTerraform",
      "Effect": "Allow",
      "Action": ["iam:ListRoles", "iam:GetPolicy", "iam:GetPolicyVersion", "iam:ListPolicies"],
      "Resource": "*"
    }
  ]
}
```

> ポイント: ロール作成・削除・PassRole を **`role/artex-lab-*` に限定**。
> これで「このプロジェクトのロールだけ扱える」状態になり、他の IAM 変更はできない。

---

## 4. Option B: 使用サービスだけに絞った自作ポリシー（厳格）

PowerUser を使わず、Phase1 で触るサービスだけ許可。IAM 部分は §3 と同じ考え方を内包。

### 作成手順
1. IAM → ポリシー → 作成 → JSON に貼り付け（`<<ACCOUNT_ID>>` 置換）→ 名前 `artex-lab-builder-policy` → 作成。
2. `artex-lab-builder`（またはグループ）にこの1本をアタッチ。

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "NetworkAndCompute",
      "Effect": "Allow",
      "Action": ["ec2:*", "elasticloadbalancing:*", "ecs:*"],
      "Resource": "*",
      "Condition": { "StringEquals": { "aws:RequestedRegion": "<<ap-northeast-1>>" } }
    },
    {
      "Sid": "LogsMonitoring",
      "Effect": "Allow",
      "Action": ["logs:*", "cloudtrail:*"],
      "Resource": "*",
      "Condition": { "StringEquals": { "aws:RequestedRegion": "<<ap-northeast-1>>" } }
    },
    {
      "Sid": "S3ForLogBuckets",
      "Effect": "Allow",
      "Action": ["s3:CreateBucket","s3:DeleteBucket","s3:PutBucketPolicy","s3:GetBucketPolicy",
        "s3:DeleteBucketPolicy","s3:PutBucketAcl","s3:GetBucketAcl","s3:PutBucketLogging",
        "s3:GetBucketLocation","s3:ListBucket","s3:PutObject","s3:GetObject","s3:DeleteObject",
        "s3:ListAllMyBuckets","s3:GetEncryptionConfiguration","s3:PutEncryptionConfiguration"],
      "Resource": ["arn:aws:s3:::artex-lab-*", "arn:aws:s3:::artex-lab-*/*"]
    },
    {
      "Sid": "IamForProjectRoles",
      "Effect": "Allow",
      "Action": ["iam:CreateRole","iam:DeleteRole","iam:GetRole","iam:TagRole","iam:UntagRole",
        "iam:AttachRolePolicy","iam:DetachRolePolicy","iam:PutRolePolicy","iam:DeleteRolePolicy",
        "iam:GetRolePolicy","iam:ListRolePolicies","iam:ListAttachedRolePolicies"],
      "Resource": "arn:aws:iam::<<ACCOUNT_ID>>:role/artex-lab-*"
    },
    {
      "Sid": "PassProjectRoles",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::<<ACCOUNT_ID>>:role/artex-lab-*",
      "Condition": { "StringEquals": { "iam:PassedToService":
        ["ecs-tasks.amazonaws.com","vpc-flow-logs.amazonaws.com"] } }
    },
    {
      "Sid": "ReadOnlyHelpers",
      "Effect": "Allow",
      "Action": ["iam:ListRoles","iam:GetPolicy","iam:GetPolicyVersion","sts:GetCallerIdentity",
        "elasticloadbalancing:Describe*","ec2:Describe*","ecs:Describe*","ecs:List*","logs:Describe*"],
      "Resource": "*"
    }
  ]
}
```

> 注意点:
> - `ec2:*` は VPC/サブネット/SG/FlowLogs/Describe を広く含むため、resource 単位の絞り込みは難しく
>   **リージョン条件**で代替するのが現実的。もっと絞るなら個別アクション列挙に差し替え可。
> - CloudTrail を**組織証跡**にする場合は追加権限が必要（今回は単一アカウント証跡なので上記で足りる）。
> - 不足で `AccessDenied` が出たら、エラーに出る **Action 名をこのポリシーに足す**のが最短。
>   （`terraform apply` のエラー文に不足アクションが明示される）

---

## 5. 切替と確認

```bash
# 作ったプロファイルで誰として動くか確認（builderユーザーになっていること）
aws sts get-caller-identity --profile artex-lab

# Terraform から使う: provider で profile 指定 or 環境変数
export AWS_PROFILE=artex-lab
terraform plan     # ここで権限不足が出たら §4 の注意点どおり不足Actionを追加
```

`provider.tf` に明示する場合:
```hcl
provider "aws" {
  region  = var.region
  profile = "artex-lab"   # ← admin ではなく builder プロファイルを使う
}
```

---

## 6. チェックリスト

- [ ] `artex-lab-builder` ユーザー作成済み・**MFA有効**
- [ ] root / AdministratorAccess を常用していない
- [ ] Option A（PowerUser＋iam-limited）か Option B（builder-policy）のどちらかをアタッチ
- [ ] `aws sts get-caller-identity --profile artex-lab` が builder を返す
- [ ] `terraform plan/apply` が通る（不足時はエラーのAction名を追記）
- [ ] 検証終了後、不要なら **アクセスキーを無効化/削除**

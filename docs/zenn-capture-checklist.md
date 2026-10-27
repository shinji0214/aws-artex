# Zenn記事用 撮影・ログ取得チェックリスト

> 検証中に「後から取り直すのが面倒なもの」を取り逃さないためのリスト。フェーズ別に、撮るもの・記事での使い道・撮り逃したときの再現方法をまとめる。
> 記事構成案は [`zenn-article-outline.md`](zenn-article-outline.md)。最終更新: 2026-10-27

---

## 0. 撮影の共通ルール

### ファイル名と保存先
- 保存先: `D:\study\aws-artex\captures\pX\`（**リポジトリにはコミットしない**。`.gitignore` に `captures/` を追加済み）
- 命名: `pX-連番-内容.png`（例: `p2-03-planner-first-plan.png`）。ログは `.txt` / `.json` で同じ連番に。
- 撮ったら `captures/README.txt` に「時刻(JST)・何をした直後か」を1行メモ。**Phase3でログと時刻を突き合わせるのに必須。**

### 時刻をそろえる（最重要）
- ARTEX実行の **開始時刻・終了時刻を秒まで** 控える（PowerShell: `Get-Date -Format o`）。
- AWSコンソールのタイムゾーン表示を **JST か UTC のどちらかに統一**（記事内でも明記）。CloudWatch Logs Insights は右上で切替可能。

### マスキング（公開前に必ず）

| 情報 | 出る場所 | 対応 |
|---|---|---|
| **AWSアカウントID**（12桁） | コンソール右上、ARN、CloudTrail、**S3バケット名 `artex-lab-cloudtrail-<ID>`**、`terraform output account_id`、`aws sts get-caller-identity` | `123456789012` に置換 or 塗りつぶし |
| **自宅/作業元のグローバルIP** | SG ルール、Flow Logs の `srcaddr`、`terraform.tfvars`、`checkip` の出力、アプリログ | `203.0.113.10`（ドキュメント用IP, RFC5737）に置換 |
| **EC2のパブリックIP / app_url** | `terraform output`、ブラウザのURLバー、ARTEXのターゲット登録画面 | `198.51.100.20` 等に置換。destroy後でも再利用され得るので必ず隠す |
| **Anthropic APIキー** | `.env`、ARTEXのLLM設定画面、console.anthropic.com | **画面に表示させない**。写り込んだら撮り直し（塗りつぶしより安全）。万一公開したら即ローテーション |
| ARTEXの管理パスワード / セットアップトークン | `docker compose logs artex` の `[auth]` 行、`/setup` | 写さない |
| `POSTGRES_PASSWORD` | `.env` | 写さない |
| IAMアクセスキーID（`AKIA...`） | `aws configure`、`~/.aws/credentials`、CloudTrail の `accessKeyId` | 塗りつぶし |
| インスタンスID / ENI ID / VPC ID | コンソール、Flow Logs のストリーム名 | 必須ではないが気になるなら一部伏せ字 |
| PC名・ユーザー名 | PowerShellのプロンプト、パス `C:\Users\<名前>` | プロンプトを短くしてから撮る（`function prompt { "PS> " }`） |

> テキストで貼るログは、公開前に `captures/` 全体を「アカウントID・自IP・EC2 IP・`AKIA`・`sk-ant`」で grep して残りが無いか確認する。
> 画像は塗りつぶしではなく **単色の矩形で完全に覆う**（モザイク・ぼかしは復元される場合がある）。

---

## P0: IAM（構築用ユーザーの切り出し）

| # | 撮るもの | 記事での使い道 | 状態 |
|---|---|---|---|
| P0-1 | IAMユーザー `artex-lab-builder` の「許可」タブ（PowerUserAccess＋iam-limited が付いている状態） | admin常用を避けた構成の説明 | ☐ |
| P0-2 | `iam-limited` ポリシーのJSON（`artex-lab-*` 限定・PassRole対象サービス） | 「最小権限で作る」節のコード | ☐ |
| P0-3 | `aws sts get-caller-identity --profile artex-lab` の出力 | builderで動いている証拠（**Account/Arnをマスク**） | ☐ |
| P0-4 | apply が権限不足で止まったエラー（instance-profile 作成 / PassRole） | ハマりどころとして記事映えする | ☐ |

**撮り逃した場合の再現:**
- P0-1〜3 はいつでも撮れる（コンソール / CLI を開くだけ）。
- P0-4 はエラー文面の再現が手間なので、**エラーメッセージのテキストを `docs/phase0-iam-setup.md` の記述から再構成**し、「当時のエラー（要約）」として載せれば十分。どうしても画面が欲しければ、テスト用にポリシーから `iam:CreateInstanceProfile` を一時的に外して `terraform apply` → 撮影 → 戻す（**戻し忘れ注意**）。

---

## P1: Terraform構築（※完了済み・撮り直し前提）

Phase1は撮影前に完了しているため、**次回 apply 時に以下をまとめて撮る**（apply→destroyの通常運用の中で撮れる）。

| # | 撮るもの | 記事での使い道 | 状態 |
|---|---|---|---|
| P1-1 | 構成図（Internet→EC2(Docker)→Juice Shop＋Flow Logs/CloudTrail/CloudWatch） | 冒頭の全体像。draw.io等で作成 | ☐ |
| P1-2 | `terraform plan` の末尾 `Plan: 23 to add, 0 to change, 0 to destroy.` | リソース数の提示 | ☐ |
| P1-3 | `terraform apply` 完了と `Outputs:`（**app_url / account_id をマスク**） | 構築完了の証拠 | ☐ |
| P1-4 | ブラウザで Juice Shop トップ画面（**URLバーのIPをマスク**） | ターゲットの紹介 | ☐ |
| P1-5 | EC2 のセキュリティグループ inbound（80番が `/32` 2つだけ） | 「脆弱アプリを全公開しない」配慮の説明。**IPマスク** | ☐ |
| P1-6 | CloudWatch Logs のロググループ一覧（`/artex-lab/juice-shop`、`/artex-lab/vpc-flow-logs`） | ログの置き場所紹介 | ☐ |
| P1-7 | VPC → フローログ タブ（送信先 CloudWatch Logs / ALL） | Flow Logs 設定 | ☐ |
| P1-8 | CloudTrail の証跡 `artex-lab-trail`（**S3バケット名にアカウントIDが入るのでマスク**） | CloudTrail 設定 | ☐ |
| P1-9 | （経緯用）Fargate で `account blocked` になったエラー | 「Fargate→EC2に変えた理由」 | ☐ |
| P1-10 | `terraform destroy` 完了（`Destroy complete! Resources: 23 destroyed.`） | コスト運用の締め | ☐ |

**撮り逃した場合の再現:**
```powershell
cd D:\study\aws-artex   # ec2-noalb の main.tf がある場所
terraform plan  | Tee-Object captures\p1\p1-02-plan.txt
terraform apply | Tee-Object captures\p1\p1-03-apply.txt
terraform output
# Juice Shop が 200 を返すまで2〜3分待つ（user_dataでDocker起動中）
curl.exe -s -o NUL -w "%{http_code}`n" <app_url>
```
- P1-9（Fargateエラー）は環境を戻すコストが高いので **再現しない**。当時の会話・メモからエラー文面をテキストで引用し、Service Quotas の画面（申請中の状態）を代わりに載せる。
- P1-10 は検証の最後に必ず撮れる。

---

## P2: ARTEX実行（Docker Compose / UI `localhost:8787` / Haiku で2回）

> Haiku で2回回す想定。**1回目＝UI・挙動を把握しながら撮影、2回目＝撮り逃し回収＋比較用**、と役割を分けると楽。
> 各回の開始・終了時刻（秒まで）を `captures/README.txt` に記録すること。

### セットアップ
| # | 撮るもの | 使い道 | 状態 |
|---|---|---|---|
| P2-1 | `docker compose up -d` → `docker compose ps`（artex / postgres が Up） | 起動手順 | ☐ |
| P2-2 | `/setup` 画面（**トークン・パスワード欄が空の状態で**） | 初期設定 | ☐ |
| P2-3 | LLM設定画面でモデル `claude-haiku-5-5` を選択（**APIキー欄は伏せる/未表示**） | コスト配慮の説明 | ☐ |
| P2-4 | ターゲット登録画面（Juice Shop を登録。**URLのIPマスク**） | 対象スコープの明示 | ☐ |

### 実行中（記事のメイン素材）
| # | 撮るもの | 使い道 | 状態 |
|---|---|---|---|
| P2-5 | 探索開始直後の画面＋時刻 | タイムライン起点 | ☐ |
| P2-6 | **Planner** が最初に立てた計画（何を優先したか） | 「AIはまず何を見るか」 | ☐ |
| P2-7 | **Worker** の実行ログ（送ったリクエスト・判断） | 個々の行動 | ☐ |
| P2-8 | **API探索**（`/api/`, `/rest/` 系を見つけた瞬間） | Juice Shop のAPIをどう発見したか | ☐ |
| P2-9 | **Asset Graph** の変化（序盤・中盤・終盤の3枚） | 攻撃面が広がる様子 | ☐ |
| P2-10 | **Exploration Graph** の変化（同上3枚） | 探索の分岐・深さ | ☐ |
| P2-11 | 面白かった判断・失敗・同じ所をループした箇所 | 記事の「考察」パート | ☐ |
| P2-12 | 終了時の結果 / レポート画面（発見した脆弱性一覧） | 成果 | ☐ |
| P2-13 | ダッシュボードの **LLMトークン使用量** ＋ console.anthropic.com の Usage（**金額だけ写す**） | 実コスト（読者が一番知りたい所） | ☐ |

### あると便利
- 画面録画（Win+Alt+R / Xbox Game Bar）で丸ごと録っておくと、グラフの変化を後から好きなタイミングで切り出せる。**GIF化してZennに載せるとグラフの変化が伝わりやすい。**
- `docker compose logs artex > captures\p2\artex-run1.log`（**`[auth]` 行と APIキーを含む行を削除してから**保管）。

**撮り逃した場合の再現:**
- P2-1〜P2-4 は何度でも撮れる（`docker compose down` / `up -d`）。
- P2-5〜P2-13 は探索結果が毎回変わる。**2回目の実行で回収**し、記事では「n回目の実行」と明記。グラフの序盤〜終盤を撮り逃したら、ARTEX UI に過去実行の履歴が残るか確認（残れば最終状態だけは撮れる）。
- ⚠ 再実行時は Juice Shop の EC2 が起動中か、自宅IPが変わっていないか（SG）を先に確認。

---

## P3: AWSログ確認（CloudWatch / VPC Flow Logs / CloudTrail）

> P2 で記録した **ARTEX実行の時間窓** で各ログを開く。Logs Insights のクエリは `docs/phase3-log-analysis.md` を使い回す。
> ログは保持期間 14日（Flow Logs / アプリログ）。**destroy するとロググループごと消える** ので、destroy 前に必ずエクスポート。

| # | 撮るもの | 使い道 | 状態 |
|---|---|---|---|
| P3-1 | `/artex-lab/juice-shop` の Logs Insights 結果（攻撃ペイロード `select`/`union`/`<script`/`../` で絞込） | アプリ側で攻撃がどう見えるか | ☐ |
| P3-2 | 同じロググループの時系列件数（`stats count(*) by bin(1m)`）のグラフ | 「探索開始でアクセスが跳ねる」図 | ☐ |
| P3-3 | `/artex-lab/vpc-flow-logs` の Logs Insights（`srcaddr` 別・`dstport` 別集計） | 通信量・送信元の特定（**自IPマスク**） | ☐ |
| P3-4 | Flow Logs の REJECT 集計（80番以外への到達試行があったか） | SGで弾かれた通信の見え方 | ☐ |
| P3-5 | Flow Logs の生ログ1〜2行と各フィールドの注釈 | 読み方の解説 | ☐ |
| P3-6 | CloudTrail イベント履歴（ARTEX実行時間帯） | **Web攻撃は CloudTrail に出ない** ことの実証（ここ大事） | ☐ |
| P3-7 | CloudTrail で terraform apply/destroy の操作（`RunInstances` 等）が見える画面 | CloudTrail に何が出るかの対比（**アカウントID・アクセスキーIDマスク**） | ☐ |
| P3-8 | 「送信元IPで串刺し」した結果のまとめ表（自作） | 初動調査の流れの説明 | ☐ |
| P3-9 | 「どのログにも残らなかった行動」のメモ | 監視設計の改善点（記事3本目の種） | ☐ |

**エクスポート（destroy前に実行）:**
```powershell
# 例: ARTEX実行時間帯のアプリログを保存（時刻はミリ秒UNIX時間）
aws logs filter-log-events --profile artex-lab --region ap-northeast-1 `
  --log-group-name /artex-lab/juice-shop --start-time <開始ms> --end-time <終了ms> `
  --output json > captures\p3\juice-shop-run1.json
aws logs filter-log-events --profile artex-lab --region ap-northeast-1 `
  --log-group-name /artex-lab/vpc-flow-logs --start-time <開始ms> --end-time <終了ms> `
  --output json > captures\p3\flowlogs-run1.json
```
- Logs Insights の結果画面は右上「エクスポート」→ CSV / Markdown でも保存可（Markdownはそのまま記事に貼れる）。

**撮り逃した場合の再現:** destroy 前ならコンソールで何度でも撮れる。destroy 後はエクスポートしたJSONから表を作るか、P2をもう1回（Haiku）流してログを再生成する。

---

## P4: WAF前後比較

> WAF(Web ACL) は EC2 に直接付けられないため、**ALBあり構成（`terraform/ec2-alb/`）に立て直してから** 実施。ALB Access Logs もここで初めて取れる。

| # | 撮るもの | 使い道 | 状態 |
|---|---|---|---|
| P4-1 | ALBあり構成の構成図（WAF付き） | 構成の差分 | ☐ |
| P4-2 | **WAF無し**で ARTEX 実行（ALB構成）→ ALB Access Logs の 4xx/2xx 比率 | 比較のベースライン | ☐ |
| P4-3 | Web ACL の設定画面（AWS マネージドルール: Core rule set / SQLi / Known bad inputs 等） | どのルールを入れたか | ☐ |
| P4-4 | **WAF有り**で ARTEX 実行 → WAF のサンプルリクエスト画面（BLOCK されたもの） | 検知・ブロックの実例 | ☐ |
| P4-5 | WAF ログ（`terminatingRuleId`, `action`）の Logs Insights 集計 | どのルールが効いたか | ☐ |
| P4-6 | ARTEX 側の挙動差（ブロックされて探索が止まった/迂回しようとした） | AIペンテスターの反応 | ☐ |
| P4-7 | 前後比較表（リクエスト数・発見数・ブロック数・トークン消費） | 記事のまとめ | ☐ |

**撮り逃した場合の再現:** WAF は Web ACL の関連付けを外す/付けるだけで前後を切り替えられる。ARTEX をもう1回回せば再取得可能（コスト: Haiku で数十円程度）。

---

## 公開前の最終チェック

- [ ] 全画像を見直し、アカウントID・自IP・EC2 IP・APIキー・アクセスキーIDが写っていない
- [ ] テキストログを grep（アカウントID / 自IP / `AKIA` / `sk-ant`）してヒット0
- [ ] ARTEXの対象が「自分の所有環境（Juice Shop）だけ」であることを記事内に明記
- [ ] 検証後に `terraform destroy` 済み（記事公開時点でエンドポイントが生きていない）
- [ ] APIキーを使い終わったら無効化 or Spend limit を下げた

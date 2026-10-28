# Zenn記事用 撮影・ログ取得チェックリスト（ローカル検証版）

> 記事の筋書き: AWSに検証環境を構築 → ARTEXの利用規約上、ネットワーク越しの対象（自己所有でも）は使えないと判明して方針転換 → **ローカルにAWS風ログ環境を作り直し、攻撃がログにどう見えるかを学ぶ**。
> 記事構成案は [`zenn-article-outline.md`](zenn-article-outline.md)。最終更新: 2026-10-28（Run1/Run2の結果と最終構成を反映）
>
> ✅ = 撮影済み（スレッドにアップロード済み）。

---

## 0. 共通ルール

### 保存先と命名
- 保存先: `D:\study\aws-artex\captures\pX\`（**コミットしない**。`captures/` は `.gitignore` 済み）
- 命名: `pX-連番-内容.png`（例: `p3-02-planner-first-plan.png`）。ログは `.log` / `.txt` で同じ連番に。
- `captures/README.txt` に「時刻・何をした直後か」を1行ずつメモ。

### 時刻をそろえる
- ARTEX実行の **開始・終了時刻を秒まで** 控える（PowerShell: `Get-Date -Format o`）。
- nginx（ALB風ログ）・Juice Shop・ARTEX の **タイムゾーンをそろえる**（コンテナは既定UTC。記事内で「UTC表記」と明記するのが楽）。

### マスキング（公開前に必ず）

ローカル実行になったので、出てくる機密情報はかなり減る。ただし前半のAWSパートの画像には引き続き注意。

| 情報 | 出る場所 | 対応 |
|---|---|---|
| **Anthropic APIキー** | `.env`、ARTEXのLLM設定画面、console.anthropic.com | **画面に表示させない**。写ったら撮り直す。万一公開したら即ローテーション |
| ARTEX管理パスワード / セットアップトークン | `docker compose logs artex` の `[auth]` 行、`/setup` | 写さない。ログ保存時はその行を削除 |
| `POSTGRES_PASSWORD` | `.env` | 写さない |
| PC名・Windowsユーザー名 | PowerShellのプロンプト、`C:\Users\<名前>`、Docker Desktop画面 | プロンプトを短くして撮る（`function prompt { "PS> " }`） |
| 自宅LANのIP（`192.168.x.x` 等） | `ipconfig`、ログの送信元が host 経由になった場合 | 気になるなら伏せる（プライベートIPなので必須ではない） |
| **（AWSパート）アカウントID** | コンソール右上、ARN、CloudTrailバケット名 `artex-lab-cloudtrail-<ID>`、`terraform output` | `123456789012` に置換 / 塗りつぶし |
| **（AWSパート）自宅グローバルIP・EC2のIP** | SG、`terraform.tfvars`、`app_url`、ブラウザのURLバー | `203.0.113.10` / `198.51.100.20`（ドキュメント用IP）に置換 |
| （AWSパート）アクセスキーID `AKIA...` | `aws configure`、CloudTrail | 塗りつぶし |

> 公開前に `captures/` を「`sk-ant`・`AKIA`・アカウントID・自宅グローバルIP」で grep し、ヒット0を確認。
> 画像は単色の矩形で完全に覆う（モザイク・ぼかしは復元される場合がある）。

---

## P0〜P1: AWSで構築したパート（経緯として使う）

AWSラボは destroy 済み。記事では「最初はAWSでやろうとした」導入として使うので、**手元にある分で足りれば撮り直し不要**。

| # | 素材 | 記事での使い道 | 状態 |
|---|---|---|---|
| A-1 | 当初の構成図（Internet→EC2(Docker)→Juice Shop＋Flow Logs/CloudTrail/CloudWatch） | 「当初の計画」 | ☐（作図のみで可） |
| A-2 | IAM: `artex-lab-builder` の許可タブ / `iam-limited` ポリシー | admin回避の工夫（短く） | ☐ |
| A-3 | `terraform apply` 完了（`23 added`）、Juice Shop が HTTP 200 | 構築できたところ | ☐ |
| A-4 | ハマりどころ: Fargate vCPU上限（account blocked）、instance-profile / PassRole 不足 | 体験談のスパイス | ☐（テキスト引用で可） |
| A-5 | `terraform destroy` 完了 | 方針転換の区切り | ☐ |

**撮り逃した場合:** `terraform/ec2-noalb` を apply → 撮影 → destroy で、十数分・数円で撮り直せる。**このときARTEXは実行しない**（規約上の理由で方針転換したため）。A-4 のエラーはプロジェクトのメモから文面を引用すれば十分。

---

## P2: 方針転換（規約の壁）

| # | 素材 | 記事での使い道 | 状態 |
|---|---|---|---|
| B-1 | ARTEX同梱の利用規約の該当箇所（ローカル隔離環境のみ想定／ネットワーク接続先へのスキャン禁止） | **記事の転換点**。原文を短く引用し、出典（ファイル名・リポジトリ）を明記 | ☐ |
| B-2 | 「自己所有のAWS環境でもダメ」と判断した理由のメモ | 読者への注意喚起 | ☐ |
| B-3 | AWS構成とローカル構成の比較表（自作） | 何を何で代替したか | ☐ |

> B-1 は引用の範囲を最小限にし、要約＋該当箇所へのリンクにする。

---

## P3: ローカルのAWS風ログ環境の構築（構成確定）

最終構成（2026-10-28確定）:

```text
ARTEX (Docker Compose, UI localhost:8787)
    │  対象URL: http://host.docker.internal:8080/
    ▼
nginx 127.0.0.1:8080 ── ALB Access Logs と同じ形式 → local-lab/logs/alb_access.log
    │
    ▼
OWASP Juice Shop（内部 3000）── stdout = アプリログ（CloudWatch Logs 相当）
```

ログは **ALB風アクセスログ** と **アプリログ** の2系統。VPC Flow Logs風ログは実装せず（haiku/sonnet比較を優先）、CloudTrail相当はローカルに無い。

| # | 撮るもの | 記事での使い道 | 状態 |
|---|---|---|---|
| C-1 | ローカル構成図（上図を清書） | 新しい全体像 | ☐ |
| C-2 | nginx の `log_format`（ALB形式に合わせた定義） | 「ALBログを再現する」節のコード | ☐ |
| C-3 | ALBの公式フィールドと nginx 変数の対応表（自作。再現できない項目も明記） | どこまで本物に近いか | ☐ |
| ~~C-4~~ | ~~Flow Logs風ログ~~ | **欠番**（未実装。記事では「今回は見送り」と一言） | — |
| C-5 | `docker compose ps`（nginx / juice-shop / artex / postgres が Up） | 起動確認 | ☐ |
| C-6 | ブラウザで `http://localhost:8080/` の Juice Shop 画面 | 対象の紹介 | ☐ |
| C-7 | 手動アクセス1回分の `alb_access.log` 1行とアプリログ | 平常時のベースライン | ☐ |

**撮り逃した場合:** ローカルなので `docker compose down` → `up -d` でいつでも撮り直せる。

---

## P4: ARTEX実行（Run1 = haiku 完走 / Run2 = sonnet 不成立）

| Run | モデル | 結果 |
|---|---|---|
| Run1 | `claude-haiku-5-5`（workers 2） | **完走**。2026-10-28 14:35:06〜14:41:41 UTC（約6分35秒）、634リクエスト、Juice Shop 116中18攻略（最大4★）、実課金 約$0.46 |
| Run2 | `claude-sonnet-5-5` | **不成立**。thinking / budget の設定がかみ合わず空応答のまま進まず、打ち切り |

> 分析は `phase2-coverage.md`、Run2の経緯は `phase2-run-log.md` を参照。
> ⚠ 実行時間は、ログ上の値（6分35秒）とARTEXのタスク一覧の Duration（6m50s）がずれている。記事ではどちらの値か明記する。

### セットアップ
| # | 撮るもの | 使い道 | 状態 |
|---|---|---|---|
| D-1 | `/setup` 画面（**トークン・パスワード欄は空の状態**） | 初期設定 | ☐ |
| D-2 | LLM設定のプロファイル（haiku / sonnet。**APIキー欄は伏せる**） | モデル選択 | ☐ |
| D-3 | New task 画面（Description に対象 `http://host.docker.internal:8080/`、Goal「このWebアプリを探索し、脆弱性を洗い出す」） | 対象がローカルであることの明示 | ✅ 撮影済み（sonnet-2 の作成画面） |

### Run1（haiku）
| # | 撮るもの | 使い道 | 状態 |
|---|---|---|---|
| D-4 | 実行中のタスク一覧（Running・workers 2・トークン増加中） | タイムラインの起点 | ✅ 撮影済み |
| D-5 | **Planner** が最初に立てた計画 | 「AIはまず何を見るか」 | ☐ |
| D-6 | **Worker** の実行ログ・Tool runs（送ったリクエスト・判断） | 個々の行動 | ☐ |
| D-7 | SQLi（`UNION SELECT NULL...` の列数探り）を試している Worker の画面 | アクセスログ（E-3）との対応 | ☐ |
| D-8 | **Assets** / グラフの最終状態 | 攻撃面の広がり | ☐ |
| D-9 | **Findings** 一覧（3/7/8/3） | 成果 | ☐ |
| D-10 | タスク詳細の Done 画面（Duration・トークン In 3.3M / Out 125k） | 実行規模 | ☐ |
| D-11 | console.anthropic.com の Usage（金額 約$0.46 だけ写す） | 実コスト | ☐ |

### Run2（sonnet、不成立）※体験談パートの素材
| # | 撮るもの | 使い道 | 状態 |
|---|---|---|---|
| D-12 | タスク一覧（haiku = Done / sonnet-2, sonnet-3 = Paused・トークン Out 0） | 「sonnetは載せられなかった」の証拠 | ✅ 撮影済み |
| D-13 | 空応答のまま進まない画面（LLM records / Logs で応答が空） | 何が起きたか | ☐ |
| D-14 | budget 関連の 400 エラー画面（エラーメッセージ全文が読めるもの） | 原因の説明 | ☐ |
| D-15 | 試した設定変更（thinking / max_tokens / budget）のメモ・画面 | 試行錯誤の記録 | ☐ |

**撮り逃した場合:**
- D-5〜D-10 は ARTEX の UI に Run1 のタスクが残っていれば後から開いて撮れる。**タスクを削除・アーカイブする前に回収**する。
- D-13〜D-14 は、sonnet のタスクを再開すれば同じエラーが再現するはず（トークンはほぼ消費しない）。
- Run1 の結果をもう一度欲しい場合は haiku で再実行（$0.5 程度）。ただし結果は毎回変わるので「n回目」と明記する。

---

## P5: ログで攻撃を可視化する（記事の後半メイン）

ログ実体: `local-lab/logs/alb_access.log`（ALB風）と Juice Shop の stdout（`docker compose logs juice-shop`）。
**Run1 の時間窓（14:35:06〜14:41:41 UTC）で切り出して `captures\p5\run1\` に保存**しておく。

| # | 撮る/作るもの | 使い道 | 状態 |
|---|---|---|---|
| E-1 | `alb_access.log` の生ログ数行＋フィールド注釈 | ALBログの読み方 | ☐ |
| E-2 | ステータスコード分布（200×350, 500×86, 401×81, 302×41 …）と1分ごとのリクエスト数 | 探索の典型パターン | ☐ |
| E-3 | **SQLi の痕跡**: `UNION SELECT NULL,...` が列数を1つずつ増やして並ぶ行 → `FROM Users` → `FROM sqlite_master` | 記事の山場の画像 | ☐ |
| E-4 | User-Agent（`curl/7.88.1`、一部 `Python-urllib/3.12`）とよく叩かれたパス上位 | ツールの痕跡 | ☐ |
| E-5 | アプリログの `Solved N-star ...` 行（例: Poison Null Byte, NoSQL Manipulation） | 攻撃の成立がアプリ側でどう見えるか | ☐ |
| E-6 | アプリログの **cheat 検知** `Cheat score ... solved in 0min (expected ~8min) ... 0.99` | アプリ自身が自動化を見抜く例 | ☐ |
| E-7 | アプリログの `Error: Unexpected path ...`（存在しない経路への探索） | 探索の痕跡 | ☐ |
| E-8 | `/api/Challenges` の solved 集計（18/116、難易度別・カテゴリ別） | 正解データとの突合 | ☐ |
| E-9 | 3層の突合表（アクセスログ＝試したこと / アプリログ＝成立したこと / Challenges＝確定結果） | 学びのまとめ | ☐ |
| ~~E-10~~ | ~~Flow Logs風ログの集計~~ | **欠番**（未実装） | — |
| E-11 | 「CloudTrailには出ない」ことの説明図（コントロールプレーンとデータプレーンの違い） | 実AWSとの差分 | ☐（作図のみ） |
| E-12 | 「どのログにも残らなかった行動」のメモ | 監視設計の改善点 | ☐ |

集計例（WSL / Git Bash。ALB形式のフィールド番号は `log_format` に合わせて調整）:
```bash
# ステータスコード分布（ALB形式: 9番目が elb_status_code）
awk '{print $9}' alb_access.log | sort | uniq -c | sort -rn
# 1分ごとのリクエスト数（2番目が time）
awk '{print substr($2,1,16)}' alb_access.log | sort | uniq -c
# SQLiの痕跡だけを時系列で抜く
grep -i 'union' alb_access.log | awk -F'"' '{print $2}'
# アプリログの成功と cheat 検知
docker compose logs juice-shop | grep -E 'Solved|Cheat score'
```

**撮り逃した場合:** 保存したログファイルがあれば集計・画像は何度でも作り直せる。ログを失った場合は haiku でもう1回実行する。

---

## 今回の対象外（記事で理由だけ書く）

- 実AWSの CloudWatch Logs / VPC Flow Logs / CloudTrail のスクリーンショット（ARTEXをAWS上の対象に向けなかったため）
- VPC Flow Logs風ログ（未実装。比較を優先したため）
- sonnet での探索結果（Run2 不成立）
- WAF の前後比較（旧P4）。次にやるなら nginx に ModSecurity を入れて比較する案がある

---

## 公開前の最終チェック

- [ ] 全画像にAPIキー・トークン・パスワード・PC名が写っていない
- [ ] AWSパートの画像にアカウントID・自宅グローバルIP・EC2のIPが写っていない
- [ ] テキストログを grep（`sk-ant` / `AKIA` / アカウントID / 自宅グローバルIP）してヒット0
- [ ] sonnet が不成立だったことを、失敗として正直に書いた
- [ ] ARTEXの対象がローカルの Juice Shop だけであること、規約に沿って方針を変えたことを記事内に明記
- [ ] APIキーを使い終わったら無効化するか、Spend limit を下げた

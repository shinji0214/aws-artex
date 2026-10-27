# Zenn記事用 撮影・ログ取得チェックリスト（ローカル検証版）

> 記事の筋書き: AWSに検証環境を構築 → ARTEXの利用規約上、ネットワーク越しの対象（自己所有でも）は使えないと判明して方針転換 → **ローカルにAWS風ログ環境を作り直し、攻撃がログにどう見えるかを学ぶ**。
> 記事構成案は [`zenn-article-outline.md`](zenn-article-outline.md)。最終更新: 2026-10-27（方針変更を反映）
>
> ⚠ ローカル構成（ポート・コンテナ名・Flow Logs風ログの形式）は動作確認後に確定する。`<<確定待ち>>` の箇所は確定後に更新すること。

---

## 0. 共通ルール

### 保存先と命名
- 保存先: `D:\study\aws-artex\captures\pX\`（**コミットしない**。`captures/` は `.gitignore` 済み）
- 命名: `pX-連番-内容.png`（例: `p3-02-planner-first-plan.png`）。ログは `.log` / `.txt` で同じ連番に。
- `captures/README.txt` に「時刻・何をした直後か」を1行ずつメモ。

### 時刻をそろえる
- ARTEX実行の **開始・終了時刻を秒まで** 控える（PowerShell: `Get-Date -Format o`）。
- nginx（ALB風ログ）・Juice Shop・Flow Logs風ログ・ARTEX の **タイムゾーンをそろえる**（コンテナは既定UTC。記事内で「UTC表記」と明記するのが楽）。

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

## P3: ローカルのAWS風ログ環境の構築

想定構成（`<<最終構成は動作確認後に確定>>`）:

```text
ARTEX (Docker Compose, UI localhost:8787)
    │  対象URL: http://host.docker.internal:8080/
    ▼
nginx :8080  ── ALB Access Logs と同じ29フィールド形式で出力
    │
    ▼
Juice Shop   ── stdout = アプリログ（CloudWatch Logs 相当）
（＋ VPC Flow Logs 風: 5タプル＋action 形式で出力予定）
（CloudTrail: ローカルに等価物なし → 記事で理由を説明）
```

| # | 撮るもの | 記事での使い道 | 状態 |
|---|---|---|---|
| C-1 | ローカル構成図（上図を清書） | 新しい全体像 | ☐ |
| C-2 | nginx の `log_format`（ALB形式29フィールドに合わせた定義） | 「ALBログを再現する」節のコード | ☐ |
| C-3 | ALBの公式フィールド一覧と nginx 変数の対応表（自作。再現できない項目も明記） | どこまで本物に近いか | ☐ |
| C-4 | Flow Logs風ログの出し方（`<<方式確定待ち>>`）と出力サンプル | Flow Logs の読み方の前振り | ☐ |
| C-5 | `docker compose ps`（nginx / juice-shop / ARTEX / postgres が Up） | 起動確認 | ☐ |
| C-6 | ブラウザで `http://localhost:8080/` の Juice Shop 画面 | 対象の紹介 | ☐ |
| C-7 | 手動アクセス1回分の各ログ1行（ALB風 / アプリ / Flow風） | 「平常時はこう見える」のベースライン | ☐ |

**撮り逃した場合:** すべてローカルなので `docker compose down` → `up -d` でいつでも撮り直せる。

---

## P4: ARTEX実行（Haikuで2回）

> 1回目＝UI・挙動を把握しながら撮影、2回目＝撮り逃し回収＋比較用。各回の開始・終了時刻を記録する。
> **実行前にログファイルを空にするかローテート**しておくと、1回分のログだけを切り出せる。

### セットアップ
| # | 撮るもの | 使い道 | 状態 |
|---|---|---|---|
| D-1 | `/setup` 画面（**トークン・パスワード欄は空の状態**） | 初期設定 | ☐ |
| D-2 | LLM設定でモデル `claude-haiku-5-5` を選んだ画面（**APIキー欄は伏せる**） | コスト配慮 | ☐ |
| D-3 | ターゲット登録画面（`http://host.docker.internal:8080/`） | 対象がローカルであることの明示 | ☐ |

### 実行中（記事のメイン素材）
| # | 撮るもの | 使い道 | 状態 |
|---|---|---|---|
| D-4 | 探索開始直後の画面＋時刻 | タイムラインの起点 | ☐ |
| D-5 | **Planner** が最初に立てた計画 | 「AIはまず何を見るか」 | ☐ |
| D-6 | **Worker** の実行ログ（送ったリクエスト・判断） | 個々の行動 | ☐ |
| D-7 | **API探索**（`/api/`, `/rest/` を見つけた瞬間） | APIの発見のしかた | ☐ |
| D-8 | **Asset Graph** の変化（序盤・中盤・終盤の3枚） | 攻撃面が広がる様子 | ☐ |
| D-9 | **Exploration Graph** の変化（同上） | 探索の分岐・深さ | ☐ |
| D-10 | 面白かった判断・失敗・ループした箇所 | 考察パート | ☐ |
| D-11 | 結果 / レポート画面 | 成果 | ☐ |
| D-12 | LLMトークン使用量 ＋ console.anthropic.com の Usage（金額だけ） | 実コスト | ☐ |

- 画面録画（Win+Alt+R）で丸ごと録っておき、グラフの変化をGIFで切り出すと伝わりやすい。
- `docker compose logs artex > captures\p4\artex-run1.log`（`[auth]` 行は削除）。

**撮り逃した場合:** 探索結果は毎回変わるので、2回目で回収して記事に「n回目の実行」と書く。Haiku なので追加コストは小さい。

---

## P5: ログで攻撃を可視化する（記事の後半メイン）

**各回の実行が終わったらすぐに、ログファイルを `captures\p5\runN\` にコピー**する（コンテナを作り直すと消える構成の場合があるため）。

| # | 撮る/作るもの | 使い道 | 状態 |
|---|---|---|---|
| E-1 | ALB風アクセスログの生ログ数行＋フィールド注釈 | ALBログの読み方 | ☐ |
| E-2 | 時間あたりリクエスト数（1分単位）のグラフ | 「探索開始で跳ねる」図 | ☐ |
| E-3 | ステータスコード比率（2xx / 4xx / 5xx）とパス上位 | 探索の典型パターン（404の量産など） | ☐ |
| E-4 | User-Agent 一覧 | ツールの痕跡が残るか | ☐ |
| E-5 | アプリログで攻撃ペイロードを grep した結果（`select` / `union` / `<script` / `../`） | アプリ側からの見え方 | ☐ |
| E-6 | 「成功してしまった」リクエスト（攻撃っぽいのに 200 / 302） | 成否の判定 | ☐ |
| E-7 | Flow Logs風ログの集計（送信元・宛先ポート・ACCEPT/REJECT） | 通信レベルの見え方 | ☐ |
| E-8 | ARTEXの行動（D-5〜D-7）とログの時刻の対応表 | **AIの判断がログにどう現れたか**（記事の山場） | ☐ |
| E-9 | 「CloudTrailにはそもそも出ない」ことの説明図（データプレーンとコントロールプレーンの違い） | 実AWSとの差分 | ☐ |
| E-10 | 「どのログにも残らなかった行動」のメモ | 監視設計の改善点 | ☐ |

集計例（PowerShellの代わりに WSL / Git Bash でも可。ALB形式のフィールド番号は確定した `log_format` に合わせる）:
```bash
# ステータスコード比率（ALB形式: 9番目が elb_status_code）
awk '{print $9}' access.log | sort | uniq -c | sort -rn
# 1分ごとのリクエスト数（2番目が time。ISO8601 の分まで切り出し）
awk '{print substr($2,1,16)}' access.log | sort | uniq -c
# パス上位（13番目以降が "METHOD URL PROTO"）
awk -F'"' '{print $2}' access.log | awk '{print $2}' | sed 's/?.*//' | sort | uniq -c | sort -rn | head -20
```
> 余力があれば、ALB形式のログを Athena の ALB テーブル定義でそのまま読めるか試すと「本物と同じ形式にした意味」が示せる（S3に置くだけなのでコストはほぼゼロ）。

**撮り逃した場合:** 保存したログファイルがあれば集計・グラフは何度でも作り直せる。ログを失ったら Haiku でもう1回回す。

---

## 今回の対象外（記事で理由だけ書く）

- 実AWSの CloudWatch Logs / VPC Flow Logs / CloudTrail のスクリーンショット（ARTEXをAWS上の対象に向けないため）
- AWS WAF の前後比較（旧P4）。やるなら次回以降に、ローカルで ModSecurity などの WAF を nginx に入れて比較する案がある。

---

## 公開前の最終チェック

- [ ] 全画像にAPIキー・トークン・パスワード・PC名が写っていない
- [ ] AWSパートの画像にアカウントID・自宅グローバルIP・EC2のIPが写っていない
- [ ] テキストログを grep（`sk-ant` / `AKIA` / アカウントID / 自宅グローバルIP）してヒット0
- [ ] ARTEXの対象がローカルの Juice Shop だけであること、規約に沿って方針を変えたことを記事内に明記
- [ ] APIキーを使い終わったら無効化するか、Spend limit を下げた

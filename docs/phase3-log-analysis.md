# Phase3 AWSログ分析リファレンス（防御側視点・先行ドラフト）

> ARTEX の行動が AWS 上のどのログの、どこに、どう記録されるか。攻撃時の初動調査観点を身につけるための早見表。
> Phase2(ARTEX実行)の実データで埋める前提の骨子。最終更新: 2026-10-26

---

## A. まず押さえる「どの攻撃がどのログに出るか」対応表

| 攻撃／探索の種類 | 主に出るログ | 補足で見るログ |
|---|---|---|
| Webアクセス・URL探索（ディレクトリ探索, パラメータ改ざん） | **ALB Access Logs** | ECS(アプリ)ログ |
| SQLi / XSS / 認証試行などアプリ攻撃 | **ECS(Juice Shop)アプリログ** | ALB Access Logs（リクエスト行） |
| ポートスキャン・到達試行・拒否通信 | **VPC Flow Logs**（ACCEPT/REJECT） | — |
| AWS API 操作（鍵の悪用, リソース列挙 等） | **CloudTrail** | — |
| WAF による検知・ブロック（Phase4以降） | **WAF Logs** | ALB Access Logs |

> 重要な住み分け: **CloudTrail = AWSコントロールプレーンのAPI操作**であり、Juice Shop への
> Web 攻撃そのものは CloudTrail には出ない。Web 攻撃は ALB / アプリログ側で見る。

---

## B. ログ別・見方メモ

### 1. ALB Access Logs（S3）
- 形式: スペース区切り。1行=1リクエスト。
- 着目フィールド: `time`, `client:port`（送信元IP）, `request`（メソッド+URL）,
  `elb_status_code`, `target_status_code`, `user_agent`, `received_bytes/sent_bytes`。
- 探索の見え方: **短時間に同一IPから多数の 404/4xx**、URL/パラメータが機械的に変化 → 探索の典型。
  user_agent が特徴的（ツール名）な場合も。
- 確認方法: S3 → Athena でクエリ（ALB用テーブル定義を作成）。`<<Athenaテーブル定義はPhase3実施時に追記>>`

### 2. ECS(Juice Shop)アプリログ（CloudWatch Logs `/artex-lab/juice-shop`）
- アプリが出す挙動ログ・エラー。攻撃ペイロードが届いた際のアプリ側反応を確認。
- Logs Insights 例:
  ```
  fields @timestamp, @message
  | filter @message like /(?i)(select|union|<script|\.\.\/|or 1=1)/
  | sort @timestamp desc
  ```

### 3. VPC Flow Logs（CloudWatch Logs `/artex-lab/vpc-flow-logs`）
- フィールド: `srcaddr dstaddr srcport dstport protocol action(ACCEPT/REJECT) packets bytes`。
- 見え方: スキャンは **多数の dstport への短時間接続**、REJECT の急増。
- Logs Insights 例（REJECT集計）:
  ```
  fields srcaddr, dstport, action
  | filter action = "REJECT"
  | stats count(*) as c by srcaddr, dstport
  | sort c desc
  ```

### 4. CloudTrail
- ARTEX が AWS API を触る構成でなければ Web 攻撃自体は出ないが、
  **環境操作・認証情報の悪用**を見る位置づけ。`eventName`, `sourceIPAddress`, `userIdentity` に着目。
- CloudTrail コンソール「イベント履歴」またはログ(S3)を Athena で。

---

## C. 攻撃発生時の初動調査観点（学習ゴール対応）

1. **時間軸をそろえる**: 疑わしい時間帯を決め、全ログを同じ時間窓で横断する。
2. **送信元IPで串刺し**: ALB(client) → Flow Logs(srcaddr) → (必要なら)CloudTrail(sourceIPAddress)。
3. **レート/異常比率**: 4xx率・REJECT率・リクエスト数の急増を基準に「普段との差分」で見る。
4. **何を狙ったか**: ALB の request/URL とアプリログのペイロードで攻撃種別を特定。
5. **成否の判定**: target_status_code=200/302 等 "通ってしまった" リクエストを抽出。
6. **記録の穴**: どの行動が「どのログにも残らなかった」かを確認（監視設計の改善点）。

---

## D. Phase2 実施後に埋める箇所（プレースホルダ）

- [ ] ARTEX 探索時の ALB ログ実サンプルと特徴（UA, レート, URL パターン）
- [ ] Planner/Worker の挙動とログ上のタイムライン対応
- [ ] Asset Graph / Exploration Graph の変化とログイベントの対応づけ
- [ ] WAF 導入前後の検知・ブロック差分（Phase4）

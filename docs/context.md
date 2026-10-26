# ARTEX動作検証 — 学習計画 / コンテキスト蓄積メモ

> yamada さんから届いた学習計画を整理したマスターメモ。手打ちで追記が来ても統合しやすい形で管理する。
> 最終更新: 2026-10-26

---

## 1. 目的

AIペンテストツール **ARTEX** を利用し、**攻撃者視点**と **AWS上での検知・監視**を学習する。
（対象は自己所有の検証環境／OWASP Juice Shop。正当な防御学習・検証目的。）

### 学習したい内容
- AIペンテスターがどのように探索するか
- 攻撃や探索が AWS ログにどう記録されるか
- CloudWatch Logs の見方
- VPC Flow Logs の見方
- WAF による検知・防御の仕組み
- 攻撃発生時に何を確認すべきか

---

## 2. 構成

```text
Internet
    │
    ▼
  ALB
    │
    ▼
ECS(Fargate)
    │
    ▼
OWASP Juice Shop

＋ CloudWatch Logs
＋ VPC Flow Logs
＋ CloudTrail
```

後続（Phase4）で追加:
```text
AWS WAF
```

---

## 3. 実施フェーズ

### Phase1: 検証環境構築
- ECS(Fargate) / Application Load Balancer / OWASP Juice Shop
- CloudWatch Logs / VPC Flow Logs / CloudTrail
- 目的: ARTEX 実行対象を用意し、攻撃ログを収集できる状態を作る

### Phase2: ARTEX実行
- 観察ポイント: 探索順序 / Planner の判断 / Worker の動作 / API探索 / Asset Graph の変化 / Exploration Graph の変化
- 目的: AIペンテスターの思考プロセスを理解する

### Phase3: AWSログ分析
- 確認対象: CloudWatch Logs / ECSログ / ALB Access Logs / VPC Flow Logs / CloudTrail
- 目的: ARTEX の行動が AWS 上でどう見えるかを理解し、どのログに何が記録されるかを把握する

### Phase4: WAF追加
- 実施: AWS WAF 導入 → ARTEX 再実行 → ログ比較
- 確認: 検知内容 / ブロック内容 / 導入前後の差分
- 目的: 防御機能の効果を確認する

---

## 4. 想定コスト

### AWS（検証環境レベル）
```text
ECS(Fargate)  : 500〜1,500円/月
ALB           : 500〜800円/月
ログ関連      : 数十〜数百円/月
合計          : 約1,500〜3,000円/月
```
停止運用でさらに削減可能。

### LLM API（ARTEX用）
```text
Claude Sonnet または OpenAI API
軽い検証  : 50〜300円/回
本格探索  : 500〜2,000円/回（従量課金）
```

---

## 5. 最終ゴール
- AIペンテスターの動作を理解する
- AWSログから探索行動を読み取れる
- WAFの役割を理解する
- 攻撃時の初動調査観点を身につける

---

## 6. 記事候補
1. **ARTEXをAWS(ECS)上で動かしてみた** — 構成 / セットアップ / AIによる探索結果
2. **ARTEXの通信はAWSログにどう見えるのか** — CloudWatch Logs / ALB Access Logs / VPC Flow Logs / CloudTrail
3. **攻撃者視点から学ぶAWS監視設計** — 何を監視すべきか / どのログを見るべきか / どのタイミングで異常に気付けるか

---

## 7. 要確認事項（本人待ち）

- [ ] **ARTEX の入手元・導入形態** … リポジトリ/配布形態（コンテナ・CLI等）、公式ドキュメントURL、使用LLM(Claude Sonnet か OpenAI か)、実行マシン（手元 PC か AWS 内の踏み台か）
- [ ] **AWS リージョン**（例: ap-northeast-1 想定）
- [ ] **アカウント**（検証専用アカウントか既存アカウントか）
- [ ] **IaC 方針**（Terraform / CloudFormation / マネジメントコンソール手動）
- [ ] **ALB の公開範囲**（インターネット全公開か、自宅 IP 等に SG で制限するか ← コスト・安全面で制限推奨）

---

## 8. 追記ログ

| 日時 | 受領内容の要約 | 反映先 |
|------|----------------|--------|
| 2026-10-26 | 初回依頼（スマホから手打ち予定の連絡） | context.md 作成 |
| 2026-10-26 | 学習計画全文（構成/Phase1-4/コスト/記事候補） | 本ファイルに整理 |
| 2026-10-26 | 追加要望: admin常用を避け構築用IAM権限を切り出したい | phase0-iam-setup.md 作成 |

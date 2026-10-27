# Phase2 ARTEX 実行手順（ドラフト）

> ARTEX（AIペンテストツール, https://github.com/jiwoochris/artex-global ）を自分のPCで動かし、
> Phase1で立てた OWASP Juice Shop を探索させる。攻撃者視点（Planner/Worker/各種グラフ）を観察するのが目的。
> 最終更新: 2026-10-27 / ステータス: ドラフト（READMEベース。UI操作の細部は実機で確認）

---

## 0. 結論（LLM課金）

- **Claude Desktop/Proのサブスクでは動かない。** ARTEXは `ANTHROPIC_API_KEY` または `OPENAI_API_KEY`（APIキー）を使う。
  → console.anthropic.com でAPIアカウント＋キー＋前払いクレジットが必要（サブスクとは別契約・別請求）。
- ARTEXの**既定モデルは `claude-opus-4-8`（高コスト: $5/$20 per 1M）**。コスト重視なら**モデルを変更**する:
  - 動作確認: `claude-haiku-5-5`（$0.10/$0.50＝最安級）
  - 本番探索: `claude-sonnet-5-5`（$2/$10＝バランス）
  - ※READMEは「レポートを人が読むなら弱すぎるモデルは避ける」と注意（gpt-4o-miniは品質劣化の例）。Haikuは確認用、実探索はSonnet以上が無難。
- 対応プロバイダは **Anthropic / OpenAI /（OpenAI互換エンドポイント）**。安さのためだけに他社契約は不要（Claude Haikuで十分安い）。

---

## 1. 前提

- [ ] **Docker Desktop**（Windows）インストール・起動済み（ARTEXはDocker Compose構成。Postgres同梱）
- [ ] **Anthropic APIキー**（console.anthropic.com → API Keys）＋クレジット前払い＋（任意）Spend limit
- [ ] Phase1のJuice Shopが稼働中（`http://13.231.179.118/`）。ARTEXは**自分のPCから**実行するので、SGで許可済みの自IP（`133.201.62.1/32`＝`artex_ip_cidr`）からアクセスでき、到達可能。
  - ※自宅IPが変わっていたら、Phase1の `main.tf` のIPを更新して `terraform apply`。

---

## 2. セットアップ（READMEのクイックスタート）

```bash
git clone https://github.com/jiwoochris/artex-global.git
cd artex-global
cp .env.example .env
```

`.env` を編集:
```dotenv
POSTGRES_PASSWORD=<任意の強いパスワード>
ANTHROPIC_API_KEY=<console で発行したAPIキー>
# コスト対策でモデルを既定(opus-4-8)から変更する場合（UIのLLM設定でも可）
ARTEX_LLM_PROVIDER=anthropic
ARTEX_LLM_MODEL=claude-sonnet-5-5
```

起動:
```bash
docker compose up -d
# 管理UI: http://localhost:8787 を開く → /setup で管理パスワード設定
# セットアップ用トークンはログから取得:
docker compose logs artex | grep -F "[auth]"
```

> モデル/キーは UI の「LLM設定（LLM settings）」ページでも設定可（プロファイル毎に model と max_tokens）。
> OpenAIの `gpt-4o` を使う場合は max_tokens を 16384 以下に（さもないと400エラー、とREADME）。

---

## 3. 探索の実行

1. ARTEXのUIにログイン。
2. **LLM設定**でモデル確認（Haikuで動作確認 → Sonnetで本探索、がコスト効率的）。
3. **ターゲットを登録**（README未記載のためUIで確認）: `http://13.231.179.118/`（Juice Shop）。
   - ⚠ 必ず自分の所有環境のみを対象に（READMEも「所有/許可のある対象だけ」「Juice Shop/DVWAで練習」と明記）。
4. 探索を開始し、以下を観察（Phase2の学習ポイント）:
   - 探索順序 / **Planner** の判断 / **Worker** の動作 / API探索
   - **Asset Graph** の変化 / **Exploration Graph** の変化
   - ダッシュボードの**LLMトークン使用量**（コスト把握）

---

## 4. コスト対策

- まず `claude-haiku-5-5` で疎通・UI確認（ほぼ数十円）。精度を見たくなったら `claude-sonnet-5-5`。
- console の **Spend limit** と**前払いクレジット**で上限を固定。
- 探索は従量課金。長時間・大規模探索ほどトークン増 → 本格探索は 500〜2,000円/回 目安。

---

## 5. 次（Phase3）への接続

ARTEX探索を回したら、その通信が AWS 側のログにどう出るかを確認（`phase3-log-analysis.md`）:
- VPC Flow Logs / CloudWatch(アプリ) / CloudTrail（今回ALB無しなのでALBログは対象外）
- 探索時のアクセス元は自PCのIP。Flow Logs の srcaddr やアプリログのリクエストで探索の足跡を追う。

---

## 6. 未確認・要実機確認

- [ ] UIでのターゲット登録・スコープ指定の具体手順（READMEに記載なし）
- [ ] `ghcr.io/jiwoochris/artex-global` イメージ取得にログインが要るか（READMEに記載なし。通常は公開イメージ）
- [ ] ARTEXが新しいモデルID（`claude-sonnet-5-5` 等）をそのまま受けるか。弾かれる場合は既定の `claude-opus-4-8` か、UIで選べるモデルに合わせる。

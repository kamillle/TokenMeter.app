# UsageBar

CodexとClaudeの残り利用枠をメニューバーに表示する、このMac用の常駐アプリです。

## 使い方

1. `UsageBar.app` を開きます。Dockには常駐せず、メニューバーに1つの項目が出ます。連携済みサービスだけを同じ項目内に表示します。
2. 項目内のどこをクリックしても詳細画面が開きます。「UsageBar」タブでは利用枠・リセット時刻と、セッション別の入力／出力トークン数・参考料金を確認でき、「Status」タブではOpenAI／Anthropicの公式稼働情報を確認できます。INPUT／OUTPUT／参考 USD の見出しをクリックすると、降順と昇順が切り替わります。並び替えを解除して更新日時順へ戻すには「クリア」ボタンを使います。詳細画面ではデータの有無にかかわらずCodex／Claudeを切り替えられます。
3. セッションの行をクリックすると、正確な記録値、キャッシュの内訳、モデル別料金が展開されます。
4. 歯車メニューから自動起動、参考単価の毎日確認／今すぐ確認、Claude連携の有効化／解除、終了を操作できます。

メニューバーの％は、主要な利用枠のうち残りが最も少ない枠です。クリック先で期間を確認できます。別モデル専用の枠は「ほかのモデル別利用枠」に表示します。利用枠を取得できていないサービスのロゴは表示しません。Claudeは連携を有効にしただけでは表示せず、公式通知から利用枠を取得できた後に表示します。10分以上前の取得値には `·` を添え、リセット時刻を過ぎた値から残り100％を推測することはありません。

## 取得対象

- Codexアプリ／CLI: このMacの `~/.codex/sessions` と `archived_sessions`。`CODEX_HOME` 設定時はその場所。内部のGuardian自動レビューは一覧から除外します。
- Claude Code: `~/.claude/projects`。`CLAUDE_CONFIG_DIR` 設定時はその場所。サブエージェントは別行です。
- **直近30日以内に更新されたローカルログ**を読みます。画面の「今日更新」「7日以内」「30日以内」はセッションの最終使用日時による絞り込みです。トークン数と料金はそのセッション全体の累計であり、その期間だけの消費量ではありません。
- 通常のClaudeチャット、ブラウザだけに存在する会話、別のMac・リモート環境のログは含みません。

## 残り利用枠

Codexはログイン済みの `codex app-server` の `account/read` と `account/rateLimits/read` を使い、アカウントID（ChatGPTのメールアドレス）と利用枠を5分ごとに取得します。アカウントIDは最後に正常取得できた値をローカルに保持し、起動直後から残り利用枠の上に表示します。新しいIDを取得できたときだけ更新するため、一時的な取得失敗やログ由来の利用枠への切り替えでは消えません。画面の更新ボタンでは直接取得も実行します。モデルへのプロンプト送信、利用枠のリセットや追加購入は行いません。

Claudeは公式の `statusLine` データに含まれる `rate_limits` を受け取ります。「Claude連携を有効にする」で既存コマンドをラップし、既存のステータスライン表示を維持します。保存するのは使用率と取得時刻だけです。連携解除時には変更前の `statusLine` を復元します。他の設定項目を変更せず、後から別のステータスラインに変えた場合はそれを上書きしません。

Claudeの枠はPro/Maxの応答後に通知されます。API・プロキシ等の接続先では通知されない場合があります。通知がない場合は **未取得／通知待ち** になります。トークン・料金の集計は機能します。

## プロバイダー ステータス

「Status」タブは、タブへ切り替えたときにOpenAIとAnthropicの公式公開ステータスAPIを確認し、全体状態、UsageBarに関連するサービス、進行中のインシデントを表示します。障害中のサービスは関連サービスの絞り込みにかかわらず表示します。右上の更新ボタンでも再取得でき、取得に失敗したプロバイダーは直前の表示を保持します。各カードとインシデントから公式ページを開けます。バックグラウンドでの定期取得は行いません。

公開ステータスは各社が集約した情報であり、契約プラン、地域、モデルなどによる個別の可用性を保証するものではありません。

## 料金の意味

**サブスク利用に対する追加請求額ではありません。** 2026-09-14に確認したAPIの公開単価を使い、標準処理・短コンテキストで換算したUSDの概算です。

- INPUTには通常入力、キャッシュ読取、キャッシュ書込を含みます。
- 料金では通常入力、キャッシュ読取、書込をそれぞれの単価で計算します。Claudeの1時間キャッシュは記録がある場合に区別します。
- OUTPUTに含まれる推論トークンを重複加算しません。
- Fast／Priority、長コンテキスト割増、地域料金、画像・検索・ツール料金、税、為替換算は含みません。実際のAPI請求やサブスク枠の消費率と一致する指標ではありません。
- 未知のモデルは「単価未設定」。合計は既知の単価で算定できる金額と「未算定」を併記します。
- `~/Library/Application Support/UsageBar/pricing.json` を用意すると、モデル単価を上書きできます。各値はUSD／100万トークンで、次回更新時に適用されます。
- UsageBarの起動中は、OpenAIとAnthropicの公式Markdown料金表を1日1回確認します。登録済みモデルをすべて解析でき、単価が明確に変わった場合だけ `official-pricing.json` に保存して次回集計から反映します。通信失敗、表形式の変更、モデル欠落時は既存値を保持します。
- 自動確認は新モデルを推測追加しません。アプリ内の自動単価より `pricing.json` のユーザー設定を優先します。歯車メニューで毎日確認を無効化できます。

## ローカルデータ

集計はアプリ内のSwift処理で30秒ごとに実行します。初回はログを読み、以後は追記分を読みます。キャッシュは `~/Library/Application Support/UsageBar/` に保存します。保存内容はセッション名・作業ディレクトリ・使用量等の集計メタデータ、CodexのアカウントID（ChatGPTのメールアドレス）と利用枠、単価確認の日時・結果です。会話本文や認証情報は保存せず、外部通信は公式料金表、公開ステータス、アカウント情報・利用枠の読み取りに限定します。セッションデータを外部に送信しません。

## ビルド・検証

Apple Silicon / macOS 14以降。実行にPythonやCommand Line Toolsは不要です。Codexの残り利用枠を直接取得する場合だけ、ログイン済みCodex CLIが必要です。Codex CLIがなくてもアプリとClaude側の機能は動作します。

```sh
bash build.sh
bash Tests/run.sh
```

ローカルのad-hoc署名です。App Store配布用の署名・公証はしていません。アプリを移動するときは一度終了し、`UsageBar.app` 全体を移してください。

## 出典

- [Codex App Server・利用枠API](https://developers.openai.com/codex/app-server#auth-endpoints)
- [OpenAI公式料金](https://developers.openai.com/api/docs/pricing)
- [OpenAI Status](https://status.openai.com/)
- [Claude Code statusLine](https://code.claude.com/docs/en/statusline)
- [Claude公式料金](https://platform.claude.com/docs/en/about-claude/pricing)
- [Anthropic Status](https://status.anthropic.com/)

## ロゴ

ユーザー指定のPNGをそのままアプリに同梱しています。メニューバーではChatGPTの黒いロゴをmacOSの明暗に合わせて表示し、Claudeは指定画像の色を維持します。

- [ChatGPTロゴ（Wikimedia）](https://thumb.wikimedia.org/wikipedia/commons/thumb/e/ef/ChatGPT-Logo.svg/960px-ChatGPT-Logo.svg.png)
- [Claudeロゴ（Seeklogo）](https://images.seeklogo.com/logo-png/55/2/claude-logo-png_seeklogo-554534.png)

# UsageBar

[English](README.md) · [简体中文](README.zh-CN.md) · **日本語**

**Claude** と **Codex** の残り使用量（5 時間 / 週間の上限）を macOS のメニューバーとデスクトップに表示します。

- **メニューバー**：`Claude 68/79%  Codex 0/47%`。5 時間の上限、週間の上限、または両方を表示。クリックすると各上限の進捗とリセット時刻を確認できます
- **2 枚のデスクトップカード**：上限カード（各上限の進捗とリセット時刻）と使用量カード（今日・リセット以降・過去 7 日間の推定コスト、リクエスト数、Tokens、キャッシュヒット率）。デスクトップ層または常に手前に表示、ドラッグで移動でき、ディスプレイごとに位置を記憶します（ディスプレイが外れるとメインに移り、戻ると元の位置へ）
- **使用量の統計**：CC Switch のような統計ページ。任意の期間のコスト、リクエスト数、Tokens、キャッシュヒット率とグラフ、アプリ別・モデル別・リクエストごとの明細（ヒット率、速度、初回応答、所要時間、ステータス。列幅と順序はドラッグで変更、行をクリックで詳細）。この Mac の Claude Code と Codex のセッション記録を差分で読み、コストは [models.dev](https://models.dev) の API 価格で推定します
- **設定**：メニューバーと 2 枚のカードはそれぞれ、表示するサービス、残り / 使用済み、レイアウト、サイズ（最大 250%）、背景、文字色、不透明度を個別に設定。ほかにログイン時に起動、外観、言語、テーマカラー、更新間隔
- **アプリ内アップデート**：GitHub Releases を毎日確認し、ワンクリックで新しいバージョンをダウンロード・SHA-256 を検証・置き換えて再起動
- **言語**：English / 简体中文 / 日本語（既定ではシステムに合わせます）
- macOS 13 以降、Apple シリコンと Intel に対応
- **Windows / Linux**：トレイ、2 枚のデスクトップカード（上限と使用量）、上限、設定を備えた[プレビュー版](https://github.com/plsy1/UsageBar/releases/tag/tauri-v0.3.0)があります（ソースは `tauri/`）

## インストール

1. [Releases](https://github.com/plsy1/UsageBar/releases) から `UsageBar-x.y.z.zip` をダウンロードして展開し、`UsageBar.app` を「アプリケーション」にドラッグします。
2. Apple Developer ID で署名していないため、初回起動時に macOS にブロックされます。次のどちらかで許可してください：
   - 一度開こうとした後、**システム設定 → プライバシーとセキュリティ** の下部にある「このまま開く」をクリック
   - またはターミナルで実行：
     ```bash
     xattr -dr com.apple.quarantine /Applications/UsageBar.app
     ```
3. メニューバーの UsageBar →「UsageBar を開く…」→ 一般 で「ログイン時に起動」をオンにできます。

## 使用量を取得するための前提条件

- **Claude**：Claude Code CLI にログインしている必要があります（`claude auth login`）。UsageBar はキーチェーンにある Claude Code のログイン情報を読み取り、`api.anthropic.com/api/oauth/usage` を呼び出します。トークンの期限が切れると、Claude Code と同じ方法で更新してキーチェーンに書き戻します。初回はキーチェーンへのアクセス許可を求められることがあります。
- **Codex**：Codex にログインしている必要があります（`~/.codex/auth.json` が存在すること）。`chatgpt.com/backend-api/wham/usage` を呼び出し、失敗した場合は `~/.codex/sessions` に記録された最新の使用量を表示します。

統計はこの Mac のセッション記録のみが対象で、コストは API 価格による推定です（サブスクリプションの実際の請求額ではありません）。価格は 1 日 1 回 models.dev から取得します。

上限の取得に使うエンドポイントは公開 API ではないため、Anthropic や OpenAI の変更によって動かなくなる可能性があります。データはお使いの Mac と各公式サービスの間でのみやり取りされます。

## ソースからビルド

```bash
./install.sh          # この Mac 向けにビルドし、/Applications にインストールして起動
./release.sh          # ユニバーサルバイナリを dist/UsageBar-<バージョン>.zip にパッケージ
```

ターミナルで使用量を表示：`/Applications/UsageBar.app/Contents/MacOS/UsageBar --print`（上限）または `--stats`（ローカルの token 統計）

## アンインストール

「UsageBar を開く…」→ 一般 で「ログイン時に起動」をオフにし、UsageBar を終了してから `/Applications/UsageBar.app` を削除します。

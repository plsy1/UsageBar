# UsageBar

[English](README.md) · [简体中文](README.zh-CN.md) · **日本語**

**Claude** と **Codex** の残り使用量（5 時間 / 週間の上限）を macOS のメニューバーとデスクトップに表示します。

- **メニューバー**：`Cc 61%  Cx 53%`（Claude Code / Codex）。それぞれ最も残りが少ない上限を表示し、クリックすると各上限の進捗とリセット時刻を確認できます
- **デスクトップカード**：デスクトップ層に表示され、ドラッグで移動できます。右クリックで更新・設定・非表示
- **使用量の統計**：CC Switch のような統計ウィンドウ。今日、週間上限のリセット以降、過去 24 時間 / 7 / 14 / 30 日間、全期間、または任意の開始・終了時刻を選び、推定コスト、リクエスト数、Tokens、キャッシュヒット率、時間別・日別のグラフ、モデル別とリクエストごとの明細。この Mac の Claude Code と Codex のセッション記録から集計し、コストは [models.dev](https://models.dev) の API 価格で推定します
- **設定**：ログイン時に起動、言語、残り / 使用済みの表示切り替え、上限と統計それぞれの更新間隔。カードの背景（なし / すりガラス ダーク / ライト）、すりガラスの濃さ、文字色、サイズ、不透明度。メニューバーの略称 / フルネーム
- **言語**：English / 简体中文 / 日本語（既定ではシステムに合わせます）
- macOS 13 以降、Apple シリコンと Intel に対応

## インストール

1. [Releases](https://github.com/plsy1/UsageBar/releases) から `UsageBar-x.y.z.zip` をダウンロードして展開し、`UsageBar.app` を「アプリケーション」にドラッグします。
2. Apple Developer ID で署名していないため、初回起動時に macOS にブロックされます。次のどちらかで許可してください：
   - 一度開こうとした後、**システム設定 → プライバシーとセキュリティ** の下部にある「このまま開く」をクリック
   - またはターミナルで実行：
     ```bash
     xattr -dr com.apple.quarantine /Applications/UsageBar.app
     ```
3. メニューバーの UsageBar → 設定… → 一般 で「ログイン時に起動」をオンにできます。

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

設定 → 一般 で「ログイン時に起動」をオフにし、UsageBar を終了してから `/Applications/UsageBar.app` を削除します。

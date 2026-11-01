# UsageBar

[English](README.md) · [简体中文](README.zh-CN.md) · **日本語**

**Claude** と **Codex** の残り使用量（5 時間 / 週間の上限）を macOS のメニューバー、Windows / Linux のトレイ、デスクトップに表示します。

- **メニューバー**：`Claude 68%/79%  Codex 0%/47%`。5 時間の上限、週間の上限、または両方を表示。1 行表示と 2 行表示（名前の下に数値）を切り替え可能。クリックすると各上限の進捗とリセット時刻を確認できます。期間の経過より速く使っている上限には ↑ が付き、メニューにはこのペースで使い切る時刻を表示します
- **通知**：上限が 80/90/95% に達したとき、リセット前に使い切るペースのとき、リセット後、Codex のリセットの期限が近いときに通知します
- **2 枚のデスクトップカード**：上限カード（各上限の進捗とリセット時刻）と使用量カード（今日・リセット以降・過去 7 日間の推定コスト、リクエスト数、Tokens、キャッシュヒット率）。デスクトップ層または常に手前に表示、ドラッグで移動でき、ディスプレイごとに位置を記憶します（ディスプレイが外れるとメインに移り、戻ると元の位置へ）
- **使用量の統計**：CC Switch のような統計ページ。任意の期間のコスト、リクエスト数、Tokens、キャッシュヒット率とグラフ、GitHub 風の日別ヒートマップ、アプリ別・モデル別・プロジェクト（作業ディレクトリ）別・リクエストごとの明細（ヒット率、速度、初回応答、所要時間、ステータス。列幅と順序はドラッグで変更、行をクリックで詳細）。この Mac の Claude Code と Codex のセッション記録を差分で読んでローカルの SQLite データベースに保存し（Claude Code が古いログを削除しても統計は残ります）、コストは [models.dev](https://models.dev) の API 価格で推定します。他のマシンで動く Codex は SSH で追加でき（リモート側で絞り込むので転送はログの数パーセント）、マシンごとに表示できます。OpenAI アカウントの日ごとの tokens はサーバー側の統計として別に表示します
- **設定**：メニューバーと 2 枚のカードはそれぞれ、表示するサービス、残り / 使用済み、レイアウト、サイズ（最大 250%）、背景、文字色、不透明度を個別に設定。ほかにログイン時に起動、外観、言語、テーマカラー、更新間隔
- **アプリ内アップデート**：GitHub Releases を毎日確認し、ワンクリックで新しいバージョンをダウンロード・SHA-256 を検証・置き換えて再起動
- **言語**：English / 简体中文 / 日本語（既定ではシステムに合わせます）
- macOS 13 以降、Apple シリコンと Intel に対応
- **Windows / Linux**：macOS 版と同じ機能をシステムトレイで。使用量の統計、通知、2 枚のカード、リモートマシン、アプリ内アップデートも使えます。Linux はトレイアイコンの横に使用率を表示し、Windows はアイコンにマウスを重ねるかクリックしてパネルで確認します。Windows 10/11 x64（Windows on ARM でも動作）、Linux x64 / arm64 に対応。ソースは `tauri/`

## インストール

### macOS

1. [Releases](https://github.com/plsy1/UsageBar/releases) から `UsageBar-x.y.z.zip` をダウンロードして展開し、`UsageBar.app` を「アプリケーション」にドラッグします。
2. Apple Developer ID で署名していないため、初回起動時に macOS にブロックされます。次のどちらかで許可してください：
   - 一度開こうとした後、**システム設定 → プライバシーとセキュリティ** の下部にある「このまま開く」をクリック
   - またはターミナルで実行：
     ```bash
     xattr -dr com.apple.quarantine /Applications/UsageBar.app
     ```
3. メニューバーの UsageBar →「UsageBar を開く…」→ 一般 で「ログイン時に起動」をオンにできます。アップデートは「情報」から。

### Windows

[Releases](https://github.com/plsy1/UsageBar/releases) から `UsageBar-x.y.z-windows-x64-setup.exe` をダウンロードして実行します。コード署名がないため、SmartScreen に「Windows によって PC が保護されました」と表示されることがあります：「詳細情報 → 実行」をクリックしてください。ログイン時の起動は「設定」、アップデートは「情報」にあります。

### Linux

- **deb**（Ubuntu、Debian）：`sudo apt install ./UsageBar-x.y.z-linux-amd64.deb`（または `arm64`）。アップデート時も新しい deb を同じ方法でインストールします。
- **AppImage**：`chmod +x UsageBar-x.y.z-linux-amd64.AppImage` してから実行。「情報」から自動でアップデートできます。
- トレイには AppIndicator 対応が必要です（Ubuntu は標準で対応。ほかの GNOME デスクトップでは AppIndicator 拡張機能を入れてください）。

## データの出どころ

### 上限

サービスごとに「一般 → データソース」で選べます。切り替えはすぐに反映されます：

| | 公式 API（既定） | ローカルのみ |
|---|---|---|
| **Claude** | キーチェーンにある Claude Code のログイン情報を読み、`api.anthropic.com/api/oauth/usage`（`/usage` コマンドと同じエンドポイント）に問い合わせます。Claude Code にログインしている必要があります（`claude auth login`、または Claude デスクトップアプリで Claude Code を使ったことがある）。初回はキーチェーンへのアクセス許可を求められることがあります。 | Claude デスクトップアプリが書き出す `~/Library/Application Support/Claude/plan-usage-history.json` を読みます。5 時間と週間の使用率だけでリセット時刻はなく、アプリが使用量を表示したときにしか更新されないため、**最新でないことがあります**。期間の長さより古い値は表示しません。 |
| **Codex** | `~/.codex/auth.json` のログイン情報を読み、`chatgpt.com/backend-api/wham/usage` に問い合わせます。リセットが残っているときはその期限も取得し、統計ページのサーバー側統計は最大 1 時間に 1 回取得します。失敗したときはセッションログの値を使います。 | セッションログを読みます。Codex は返答のたびにその時点の上限（使用率とリセット時刻）をログに記録するので、Codex を使っている間はほぼリアルタイムです。この Mac と追加したリモートマシンのログのうち最新のものを使います。 |

**公式 API で送るもの：** 本文のない GET リクエストだけで、ヘッダーはログイントークン、Codex のアカウント ID、公式クライアントと同じ User-Agent（`claude-code`、`codex-cli`）です。会話の内容や使用記録などのローカルデータは送信しません。Claude のトークンが期限切れになると、Claude Code と同じ方法で更新してキーチェーンに書き戻します。

**ローカルのみ** ではリクエストを一切送らず、キーチェーンや `auth.json` も読みません。このとき Codex のサーバー側統計とリセット回数は表示されません。

**Windows と Linux では** Claude Code がログイン情報を `~/.claude/.credentials.json`（Windows では `%USERPROFILE%\.claude`）に保存するので、キーチェーンの代わりにこのファイルを読みます。「ローカルのみ」は `%APPDATA%\Claude` または `~/.config/Claude` にある Claude デスクトップアプリの記録を読みます。これらの設定は「設定 → データソース」にあります。

上限の取得に使うエンドポイントは公開 API ではないため、Anthropic や OpenAI の変更によって動かなくなる可能性があります。

### 使用量の統計

使用量の統計にログインは不要で、データはすべてこの Mac にあります：

- **セッションログ：** `~/.claude/projects`（Claude デスクトップアプリで Claude Code を使ったセッションを含む）と `~/.codex/sessions` を差分で読みます。Claude デスクトップアプリの通常のチャットはローカルに記録が残らないため統計には含まれません（上限には含まれます）。
- **リモートマシン：** 「一般 → データソース」で追加したマシンの Codex ログを `ssh` で読み、リモート側で絞り込んでから転送します（転送量はログの数パーセント）。パスワードなしで `ssh` できる必要があり（鍵認証など）、ローカルネットワーク上のマシンは システム設定 → プライバシーとセキュリティ → ローカルネットワーク で UsageBar を許可してください。
- **ローカルデータベース：** 解析結果は `~/Library/Application Support/UsageBar/usage.sqlite`（Windows：`%APPDATA%\io.github.plsy1.usagebar`、Linux：`~/.local/share/io.github.plsy1.usagebar`）に保存され、Claude Code が古いログを削除しても統計は残ります。
- **コスト：** [models.dev](https://models.dev) の API 価格（1 日 1 回取得）による推定で、サブスクリプションの実際の請求額ではありません。

## ソースからビルド

```bash
./install.sh          # この Mac 向けにビルドし、/Applications にインストールして起動
./release.sh          # ユニバーサルバイナリを dist/UsageBar-<バージョン>.zip にパッケージ
```

Windows / Linux：`cd tauri/src-tauri && cargo tauri build`（Rust と [Tauri の前提条件](https://v2.tauri.app/start/prerequisites/) が必要）。`tauri/` への push のたびに CI がインストーラーをビルドします。

ターミナルで使用量を表示：`/Applications/UsageBar.app/Contents/MacOS/UsageBar --print`（上限）または `--stats`（ローカルの token 統計）

## アンインストール

「UsageBar を開く…」→ 一般 で「ログイン時に起動」をオフにし、UsageBar を終了してから `/Applications/UsageBar.app` を削除します。

Windows：「設定 → アプリ」から UsageBar をアンインストールします。Linux：deb は `sudo apt remove usage-bar`、AppImage はファイルを削除します。

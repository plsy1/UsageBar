# UsageBar

在 macOS 菜单栏和桌面上显示 **Claude** 与 **Codex** 的剩余用量（5 小时额度 / 每周额度）。

[English](#english) · [日本語](#日本語)

- **菜单栏**：`Cc 61%  Cx 53%`（Claude Code / Codex），显示每边最紧的那个额度；点开看每个额度的进度和重置时间
- **桌面卡片**：贴在桌面层，可拖动，右键刷新、打开设置或隐藏
- **设置**：开机启动、语言、刷新间隔；卡片背景（无 / 深色 / 浅色毛玻璃）、毛玻璃浓度、文字颜色、大小、不透明度；菜单栏简写或全名
- **语言**：中文 / 日本語 / English，默认跟随系统
- 系统要求 macOS 13 及以上，Apple 芯片和 Intel 都支持

## 安装

1. 从 [Releases](https://github.com/plsy1/UsageBar/releases) 下载 `UsageBar-x.y.z.zip`，解压后把 `UsageBar.app` 拖进「应用程序」。
2. 本 app 没有 Apple 开发者签名，第一次打开会被系统拦下。任选一种方式放行：
   - 打开一次后，到 **系统设置 → 隐私与安全性**，在页面下方点「仍要打开」；
   - 或者在终端运行：
     ```bash
     xattr -dr com.apple.quarantine /Applications/UsageBar.app
     ```
3. 打开后在菜单栏点 UsageBar → 设置… → 通用，可以开启「开机启动」。

## 读取用量的前提

- **Claude**：需要 Claude Code 命令行已登录（`claude auth login`）。UsageBar 读取钥匙串里 Claude Code 的登录信息，请求 `api.anthropic.com/api/oauth/usage`；令牌过期时会自动续期并写回钥匙串，和 Claude Code 自己的做法一致。第一次读取时系统可能弹窗询问是否允许访问钥匙串。
- **Codex**：需要 Codex 已登录（存在 `~/.codex/auth.json`）。请求 `chatgpt.com/backend-api/wham/usage`；失败时退回到 `~/.codex/sessions` 里最近一次记录的用量。

这些接口不是公开 API，Anthropic 或 OpenAI 改动后可能失效。所有数据只在本机和对应官方服务之间传输。

## 从源码构建

```bash
./install.sh          # 编译本机架构，安装到 /Applications 并启动
./release.sh          # 打包通用二进制到 dist/UsageBar-<版本>.zip
```

终端里查看用量：`/Applications/UsageBar.app/Contents/MacOS/UsageBar --print`

## 卸载

先在 设置 → 通用 里关掉「开机启动」，退出 UsageBar，再删除 `/Applications/UsageBar.app`。

---

## English

UsageBar shows your remaining **Claude** and **Codex** usage (5-hour and weekly limits) in the macOS menu bar and as a desktop card. It supports English, Japanese and Chinese, and runs on macOS 13+ (Apple silicon and Intel).

**Install:** download the zip from [Releases](https://github.com/plsy1/UsageBar/releases), move `UsageBar.app` to Applications. The app is not notarized, so allow it under **System Settings → Privacy & Security → Open Anyway**, or run `xattr -dr com.apple.quarantine /Applications/UsageBar.app`. Turn on Launch at Login in Settings → General.

**Requirements:** Claude Code logged in (`claude auth login`) and Codex logged in (`~/.codex/auth.json`). Usage comes from the same unofficial endpoints the official tools use, so it may break if they change.

## 日本語

UsageBar は **Claude** と **Codex** の残り使用量（5 時間 / 週間の上限）をメニューバーとデスクトップカードに表示します。日本語・英語・中国語に対応、macOS 13 以降（Apple シリコン / Intel）で動作します。

**インストール：** [Releases](https://github.com/plsy1/UsageBar/releases) から zip をダウンロードし、`UsageBar.app` をアプリケーションへ移動します。公証されていないため、**システム設定 → プライバシーとセキュリティ → このまま開く** で許可するか、`xattr -dr com.apple.quarantine /Applications/UsageBar.app` を実行してください。ログイン時の起動は 設定 → 一般 でオンにできます。

**前提条件：** Claude Code にログイン済み（`claude auth login`）、Codex にログイン済み（`~/.codex/auth.json`）。使用量は公式ツールと同じ非公開エンドポイントから取得するため、仕様変更で動かなくなる可能性があります。

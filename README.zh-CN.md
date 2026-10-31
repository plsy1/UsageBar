# UsageBar

[English](README.md) · **简体中文** · [日本語](README.ja.md)

在 macOS 菜单栏和桌面上显示 **Claude** 与 **Codex** 的剩余用量（5 小时额度 / 每周额度）。

- **菜单栏**：`Claude 68/79%  Codex 0/47%`，可选显示 5 小时额度、每周额度或两个都显示；点开看每个额度的进度和重置时间
- **两张桌面卡片**：额度卡片（各额度的进度和重置时间）和用量卡片（今天、重置以来或近 7 天的估算成本、请求数、Tokens、缓存命中率）。可以贴在桌面层或保持在最前，可拖动，按显示器分别记住位置——显示器断开时挪到主屏，接回来自动回去
- **用量统计**：类似 CC Switch 的统计页，任选时间范围，显示成本、请求数、Tokens、缓存命中率和走势图，以及按应用、按模型、逐条请求的明细（命中率、速度、首字、总耗时、状态码；列宽和顺序可拖动调整；点一条看详情）。数据来自本机的 Claude Code 和 Codex 会话记录，只读新增部分；成本按 [models.dev](https://models.dev) 的 API 价格估算
- **设置**：菜单栏和两张卡片各自设置显示哪几家、剩余或已用、布局、大小（最大 250%）、背景、文字颜色、不透明度；另有开机启动、外观、语言、主题色和刷新间隔
- **应用内更新**：每天自动检查 GitHub Releases，一键下载新版、校验 SHA-256、替换并重启
- **语言**：English / 简体中文 / 日本語，默认跟随系统
- 系统要求 macOS 13 及以上，Apple 芯片和 Intel 都支持
- **Windows / Linux**：有[预览版](https://github.com/plsy1/UsageBar/releases/tag/tauri-v0.2.0)，包含托盘、桌面卡片、额度和设置（源码在 `tauri/`）

## 安装

1. 从 [Releases](https://github.com/plsy1/UsageBar/releases) 下载 `UsageBar-x.y.z.zip`，解压后把 `UsageBar.app` 拖进「应用程序」。
2. 本 app 没有 Apple 开发者签名，第一次打开会被系统拦下。任选一种方式放行：
   - 打开一次后，到 **系统设置 → 隐私与安全性**，在页面下方点「仍要打开」；
   - 或者在终端运行：
     ```bash
     xattr -dr com.apple.quarantine /Applications/UsageBar.app
     ```
3. 打开后在菜单栏点 UsageBar →「打开 UsageBar…」→ 通用，可以开启「开机启动」。

## 读取用量的前提

- **Claude**：需要 Claude Code 命令行已登录（`claude auth login`）。UsageBar 读取钥匙串里 Claude Code 的登录信息，请求 `api.anthropic.com/api/oauth/usage`；令牌过期时会自动续期并写回钥匙串，和 Claude Code 自己的做法一致。第一次读取时系统可能弹窗询问是否允许访问钥匙串。
- **Codex**：需要 Codex 已登录（存在 `~/.codex/auth.json`）。请求 `chatgpt.com/backend-api/wham/usage`；失败时退回到 `~/.codex/sessions` 里最近一次记录的用量。

用量统计只包含这台 Mac 上的会话记录；成本是按 API 价格的估算，不是订阅实际扣的钱。价格每天从 models.dev 下载一次。

额度接口不是公开 API，Anthropic 或 OpenAI 改动后可能失效。所有数据只在本机和对应官方服务之间传输。

## 从源码构建

```bash
./install.sh          # 编译本机架构，安装到 /Applications 并启动
./release.sh          # 打包通用二进制到 dist/UsageBar-<版本>.zip
```

终端里查看用量：`/Applications/UsageBar.app/Contents/MacOS/UsageBar --print`（额度）或 `--stats`（本机 token 统计）

## 卸载

先在「打开 UsageBar…」→ 通用 里关掉「开机启动」，退出 UsageBar，再删除 `/Applications/UsageBar.app`。

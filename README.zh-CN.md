# UsageBar

[English](README.md) · **简体中文** · [日本語](README.ja.md)

在 macOS 菜单栏和桌面上显示 **Claude** 与 **Codex** 的剩余用量（5 小时额度 / 每周额度）。

- **菜单栏**：`Cc 61%  Cx 53%`（Claude Code / Codex），显示每边最紧的那个额度；点开看每个额度的进度和重置时间
- **桌面卡片**：贴在桌面层，可拖动，右键刷新、打开设置或隐藏
- **用量统计**：类似 CC Switch 的统计窗口，可选今天、周额度重置以来、近 24 小时 / 7 / 14 / 30 天、全部时间或自选起止时间，显示估算成本、请求数、Tokens、缓存命中率，按小时或按天的走势图，以及按模型和逐条请求的明细。数据来自本机的 Claude Code 和 Codex 会话记录，成本按 [models.dev](https://models.dev) 的 API 价格估算
- **设置**：开机启动、语言、显示剩余或已使用、额度和统计各自的刷新间隔；卡片背景（无 / 深色 / 浅色毛玻璃）、毛玻璃浓度、文字颜色、大小、不透明度；菜单栏简写或全名
- **语言**：English / 简体中文 / 日本語，默认跟随系统
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

用量统计只包含这台 Mac 上的会话记录；成本是按 API 价格的估算，不是订阅实际扣的钱。价格每天从 models.dev 下载一次。

额度接口不是公开 API，Anthropic 或 OpenAI 改动后可能失效。所有数据只在本机和对应官方服务之间传输。

## 从源码构建

```bash
./install.sh          # 编译本机架构，安装到 /Applications 并启动
./release.sh          # 打包通用二进制到 dist/UsageBar-<版本>.zip
```

终端里查看用量：`/Applications/UsageBar.app/Contents/MacOS/UsageBar --print`（额度）或 `--stats`（本机 token 统计）

## 卸载

先在 设置 → 通用 里关掉「开机启动」，退出 UsageBar，再删除 `/Applications/UsageBar.app`。

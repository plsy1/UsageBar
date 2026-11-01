# UsageBar

[English](README.md) · **简体中文** · [日本語](README.ja.md)

在 macOS 菜单栏、Windows / Linux 托盘和桌面上显示 **Claude** 与 **Codex** 的剩余用量（5 小时额度 / 每周额度）。

- **菜单栏**：`Claude 68%/79%  Codex 0%/47%`，可选显示 5 小时额度、每周额度或两个都显示，单行或双行（名称在上、数值在下）样式；点开看每个额度的进度和重置时间。用得比时间快的额度会标上 ↑，菜单里写出按这个速度预计何时用完
- **通知**：额度用到 80/90/95%、按现在的速度会在重置前用完、额度重置后、Codex 的重置次数快到期时提醒
- **两张桌面卡片**：额度卡片（各额度的进度和重置时间）和用量卡片（今天、重置以来或近 7 天的估算成本、请求数、Tokens、缓存命中率）。可以贴在桌面层或保持在最前，可拖动，按显示器分别记住位置——显示器断开时挪到主屏，接回来自动回去
- **用量统计**：类似 CC Switch 的统计页，任选时间范围，显示成本、请求数、Tokens、缓存命中率和走势图、GitHub 风格的每日热力图，以及按应用、按模型、按项目（工作目录）、逐条请求的明细（命中率、速度、首字、总耗时、状态码；列宽和顺序可拖动调整；点一条看详情）。数据来自本机的 Claude Code 和 Codex 会话记录，只读新增部分，存进本机的 SQLite 数据库（Claude Code 清理旧日志后统计也还在）；成本按 [models.dev](https://models.dev) 的 API 价格估算。跑在其他机器上的 Codex 可以通过 SSH 添加（在远程先过滤，只传日志的百分之几），可按机器筛选；OpenAI 账号的每日 tokens 单独作为服务端数据统计显示
- **设置**：菜单栏和两张卡片各自设置显示哪几家、剩余或已用、布局、大小（最大 250%）、背景、文字颜色、不透明度；另有开机启动、外观、语言、主题色和刷新间隔
- **应用内更新**：每天自动检查 GitHub Releases，一键下载新版、校验 SHA-256、替换并重启
- **语言**：English / 简体中文 / 日本語，默认跟随系统
- 系统要求 macOS 13 及以上，Apple 芯片和 Intel 都支持
- **Windows / Linux**：功能和 macOS 版一致，放在系统托盘里：用量统计、通知、两张卡片、远程机器、应用内更新都有。Linux 在托盘图标旁边显示百分比；Windows 把鼠标放在图标上或点开小面板查看。支持 Windows 10/11 x64（Windows on ARM 也能运行）、Linux x64 和 arm64；源码在 `tauri/`

## 安装

### macOS

1. 从 [Releases](https://github.com/plsy1/UsageBar/releases) 下载 `UsageBar-x.y.z.zip`，解压后把 `UsageBar.app` 拖进「应用程序」。
2. 本 app 没有 Apple 开发者签名，第一次打开会被系统拦下。任选一种方式放行：
   - 打开一次后，到 **系统设置 → 隐私与安全性**，在页面下方点「仍要打开」；
   - 或者在终端运行：
     ```bash
     xattr -dr com.apple.quarantine /Applications/UsageBar.app
     ```
3. 打开后在菜单栏点 UsageBar →「打开 UsageBar…」→ 通用，可以开启「开机启动」。更新在「关于」里。

### Windows

从 [Releases](https://github.com/plsy1/UsageBar/releases) 下载并运行 `UsageBar-x.y.z-windows-x64-setup.exe`。安装包没有代码签名，SmartScreen 可能提示「Windows 已保护你的电脑」：点「更多信息 → 仍要运行」。开机启动在「设置」里，更新在「关于」里。

### Linux

- **deb**（Ubuntu、Debian）：`sudo apt install ./UsageBar-x.y.z-linux-amd64.deb`（或 `arm64`）。更新时同样装新的 deb。
- **AppImage**：`chmod +x UsageBar-x.y.z-linux-amd64.AppImage` 后运行，可以在「关于」里自动更新。
- 托盘需要 AppIndicator 支持（Ubuntu 自带；其他 GNOME 桌面请安装 AppIndicator 扩展）。

## 数据从哪来

### 额度

每家可以分别选择，在「通用 → 数据来源」里切换，切换后立即生效：

| | 官方接口（默认） | 仅本地 |
|---|---|---|
| **Claude** | 读取钥匙串里 Claude Code 的登录信息，请求 `api.anthropic.com/api/oauth/usage`（和 `/usage` 命令同一个接口）。需要 Claude Code 已登录（`claude auth login`，或在 Claude 桌面 app 里用过 Claude Code）。第一次读取时系统可能询问是否允许访问钥匙串。 | 读 Claude 桌面 app 留下的 `~/Library/Application Support/Claude/plan-usage-history.json`：只有 5 小时和本周的已用百分比，没有重置时间，而且只在 app 查看用量时才更新，**可能不是最新**。超过窗口长度的旧数据不显示。 |
| **Codex** | 读取 `~/.codex/auth.json` 里的登录信息，请求 `chatgpt.com/backend-api/wham/usage`；有可用的额度重置次数时再查一次到期时间，统计页的服务端数据统计最多一小时查一次。请求失败时退回到会话日志里的数据。 | 读会话日志：Codex 每次回复后都会在日志里记下当时的额度（已用比例和重置时间），只要在用 Codex 就几乎是实时的。本机和添加的远程机器的日志都算，取最新的一份。 |

**官方接口会发什么**：只发不带请求体的 GET 请求，请求头里是登录令牌、Codex 的账号 ID，以及和官方客户端一样的 User-Agent（`claude-code`、`codex-cli`）；不会上传会话内容、用量记录或其他本地数据。Claude 的令牌过期时，UsageBar 会像 Claude Code 一样用刷新令牌换一个新的并写回钥匙串。

**仅本地**：不发任何请求，也不读钥匙串和 `auth.json`；统计页的 Codex 服务端数据统计和额度重置次数这时不显示。

**Windows 和 Linux 上**：Claude Code 把登录信息存在 `~/.claude/.credentials.json`（Windows 上是 `%USERPROFILE%\.claude`），读这个文件而不是钥匙串；「仅本地」读 `%APPDATA%\Claude` 或 `~/.config/Claude` 里 Claude 桌面 app 的记录。这些选项在「设置 → 数据来源」里。

额度接口不是公开 API，Anthropic 或 OpenAI 改动后可能失效。

### 用量统计

用量统计不需要登录，所有数据都在本机：

- **会话日志**：本机的 `~/.claude/projects`（包括在 Claude 桌面 app 里用 Claude Code 的会话）和 `~/.codex/sessions`；只读新写入的部分。Claude 桌面 app 里的普通聊天不在本地留记录，所以不算在统计里（但算在额度里）。
- **远程机器**：在「通用 → 数据来源」里添加的机器上的 Codex 日志，用 `ssh` 读取，在远程先过滤再传回（只传原日志的百分之几）。需要能免密登录（比如用密钥）；局域网里的机器还要在 系统设置 → 隐私与安全性 → 本地网络 里允许 UsageBar。
- **本机数据库**：解析结果存在 `~/Library/Application Support/UsageBar/usage.sqlite`（Windows：`%APPDATA%\io.github.plsy1.usagebar`，Linux：`~/.local/share/io.github.plsy1.usagebar`），Claude Code 清理旧日志后统计也还在。
- **成本**：按 [models.dev](https://models.dev) 的 API 价格估算（每天下载一次价格表），不是订阅实际扣的钱。

## 从源码构建

```bash
./install.sh          # 编译本机架构，安装到 /Applications 并启动
./release.sh          # 打包通用二进制到 dist/UsageBar-<版本>.zip
```

Windows / Linux：`cd tauri/src-tauri && cargo tauri build`（需要 Rust 和 [Tauri 的依赖](https://v2.tauri.app/start/prerequisites/)）；每次推送 `tauri/` 的改动，CI 都会编出安装包。

终端里查看用量：`/Applications/UsageBar.app/Contents/MacOS/UsageBar --print`（额度）或 `--stats`（本机 token 统计）

## 卸载

先在「打开 UsageBar…」→ 通用 里关掉「开机启动」，退出 UsageBar，再删除 `/Applications/UsageBar.app`。

Windows：在「设置 → 应用」里卸载 UsageBar。Linux：deb 用 `sudo apt remove usage-bar`，AppImage 直接删掉文件。

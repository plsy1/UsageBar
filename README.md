# UsageBar

macOS 菜单栏 + 桌面卡片，显示 Claude 和 Codex 的剩余用量（5 小时 / 每周额度）。

- 菜单栏：`Cc 61%  Cx 53%`（Claude Code / Codex），取每边最紧的那个额度
- 桌面卡片：贴在桌面层，可拖动，右键可刷新、打开设置或隐藏
- 设置（菜单里的「设置…」）：卡片背景（无 / 深色 / 浅色毛玻璃）、毛玻璃浓度、文字颜色、大小、整体不透明度、是否显示重置时间、显示哪几家、菜单栏用简写还是全名、刷新间隔
- 默认每 5 分钟自动刷新，唤醒后也会刷新

## 安装

```bash
./install.sh
```

编译后装到 `/Applications/UsageBar.app`，并通过 LaunchAgent 开机自启。

命令行查看：

```bash
/Applications/UsageBar.app/Contents/MacOS/UsageBar --print
```

## 数据来源

- **Claude**：钥匙串里 Claude Code 的登录信息（`Claude Code-credentials`），请求 `api.anthropic.com/api/oauth/usage`。需要先 `claude auth login`；令牌过期会自动续期并写回钥匙串。
- **Codex**：`~/.codex/auth.json`，请求 `chatgpt.com/backend-api/wham/usage`；失败时退回到 `~/.codex/sessions` 里最近一次记录的用量。

## 卸载

```bash
launchctl bootout gui/$(id -u)/local.usagebar
rm -rf /Applications/UsageBar.app ~/Library/LaunchAgents/local.usagebar.plist
```

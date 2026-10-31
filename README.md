# UsageBar

macOS 菜单栏 + 桌面卡片，显示 Claude 和 Codex 的剩余用量（5 小时 / 每周额度）。

- 菜单栏：`Cl 61%  Cx 53%`，取每边最紧的那个额度，绿 / 橙 / 红表示余量
- 桌面卡片：贴在桌面层的毛玻璃卡片，可拖动，右键可刷新或隐藏
- 每 5 分钟自动刷新，唤醒后也会刷新

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

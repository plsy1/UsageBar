#!/bin/zsh
# 从源码编译 UsageBar 并安装到 /Applications，然后启动
set -euo pipefail
cd "${0:A:h}"

APP="/Applications/UsageBar.app"
LEGACY="$HOME/Library/LaunchAgents/local.usagebar.plist"
ARGS=()

if [[ -f "$LEGACY" ]]; then
  # 旧版用 LaunchAgent 开机自启；换成系统的登录项，由 app 自己管理
  launchctl bootout "gui/$(id -u)/local.usagebar" 2>/dev/null || true
  rm "$LEGACY"
  ARGS=(--args --enable-login-item)
fi
pkill -x UsageBar 2>/dev/null && sleep 1 || true

./build.sh "$APP"
open "$APP" $ARGS
echo "已安装并启动：$APP（开机启动在 设置 → 通用 里开关）"

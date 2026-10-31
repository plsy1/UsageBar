#!/bin/zsh
# 编译并打包 UsageBar.app
# 用法：./build.sh <输出的 .app 路径> [--universal]
#   --universal  同时编译 Apple 芯片和 Intel（发布用）；不加只编译本机架构
set -euo pipefail
cd "${0:A:h}"

APP="${1:?用法：./build.sh <输出的 .app 路径> [--universal]}"
[[ "$APP" == *.app ]] || { echo "输出路径必须以 .app 结尾"; exit 1; }
VERSION="$(cat VERSION)"
MIN_OS="13.0"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build

if [[ "${2:-}" == "--universal" ]]; then
  for arch in arm64 x86_64; do
    swiftc -O -target "$arch-apple-macos$MIN_OS" -o "build/UsageBar-$arch" UsageBar.swift
  done
  lipo -create -output "$APP/Contents/MacOS/UsageBar" build/UsageBar-arm64 build/UsageBar-x86_64
else
  swiftc -O -target "$(uname -m)-apple-macos$MIN_OS" -o "$APP/Contents/MacOS/UsageBar" UsageBar.swift
fi

cp assets/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.usagebar</string>
  <key>CFBundleName</key><string>UsageBar</string>
  <key>CFBundleExecutable</key><string>UsageBar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign --force --sign - "$APP"
echo "已编译：$APP（$VERSION）"

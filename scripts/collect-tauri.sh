#!/bin/zsh
# 发版用：把 CI（Tauri build）编好的 Windows / Linux 安装包下载下来，改成统一的文件名放进 dist/，并打印 SHA-256
#   scripts/collect-tauri.sh [运行 ID]   不给 ID 就用当前提交的那次
# 文件名：UsageBar-<版本>-windows-x64-setup.exe、UsageBar-<版本>-linux-{amd64,arm64}.{deb,AppImage}
# （应用内更新按这些名字找安装包、按发布说明里的「哈希  文件名」校验）
set -euo pipefail
cd "${0:A:h}/.."

VERSION="$(cat VERSION)"
CONF="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' tauri/src-tauri/tauri.conf.json | head -1)"
[[ "$CONF" == "$VERSION" ]] || { echo "tauri.conf.json 的版本 $CONF 和 VERSION $VERSION 不一致"; exit 1; }

RUN="${1:-$(gh run list --workflow tauri.yml --commit "$(git rev-parse HEAD)" -L 1 --json databaseId,conclusion -q '.[] | select(.conclusion == "success") | .databaseId')}"
[[ -n "$RUN" ]] || { echo "当前提交还没有编好的 Tauri build"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
gh run download "$RUN" -D "$TMP"
mkdir -p dist
for f in "$TMP"/**/*(.); do
  case "${f:t}" in
    *-setup.exe)        name="windows-x64-setup.exe" ;;
    *amd64.deb)         name="linux-amd64.deb" ;;
    *arm64.deb)         name="linux-arm64.deb" ;;
    *amd64.AppImage)    name="linux-amd64.AppImage" ;;
    *aarch64.AppImage)  name="linux-arm64.AppImage" ;;
    *) continue ;;
  esac
  [[ "${f:t}" == *"$VERSION"* ]] || { echo "${f:t} 不是 $VERSION 版"; exit 1; }
  cp "$f" "dist/UsageBar-$VERSION-$name"
done
(cd dist && shasum -a 256 UsageBar-"$VERSION"-*)

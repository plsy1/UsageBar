#!/bin/zsh
# 打包发布用的通用二进制：dist/UsageBar-<版本>.zip
set -euo pipefail
cd "${0:A:h}"

VERSION="$(cat VERSION)"
rm -rf dist
./build.sh dist/UsageBar.app --universal
ditto -c -k --keepParent dist/UsageBar.app "dist/UsageBar-$VERSION.zip"
lipo -archs dist/UsageBar.app/Contents/MacOS/UsageBar
shasum -a 256 "dist/UsageBar-$VERSION.zip"

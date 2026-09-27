#!/usr/bin/env bash
#
# 把 dist/AppBox.app 打包成可分发的 DMG 磁盘镜像。
# 先生成/刷新 .app，再用临时拷贝（附 Applications 快捷方式）创建只读 DMG。
#
# 用法：scripts/build-dmg.sh
# 产物：dist/AppBox-<version>.dmg

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="AppBox"

"$ROOT/scripts/build-app.sh"

VERSION="$(plutil -extract CFBundleShortVersionString raw "$ROOT/dist/$APP_NAME.app/Contents/Info.plist")"

DMG="$ROOT/dist/$APP_NAME-$VERSION.dmg"
STAGING="$ROOT/dist/dmg-staging"

echo "==> 准备 DMG 内容"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$ROOT/dist/$APP_NAME.app" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "==> 创建 DMG：$DMG"
rm -f "$DMG"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "$DMG" >/dev/null

rm -rf "$STAGING"

echo "==> 校验签名"
codesign --verify --verbose=2 "$ROOT/dist/$APP_NAME.app" 2>&1 | tail -1 || true
hdiutil verify "$DMG" >/dev/null

echo "==> 完成：$DMG"

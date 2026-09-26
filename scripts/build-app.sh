#!/usr/bin/env bash
#
# 把 SwiftPM 产出的可执行文件组装成 AppBox.app。
# SwiftPM 没有 app bundle 的概念，bundle 结构、Info.plist 与临时签名都在这里手工完成。
#
# 用法：scripts/build-app.sh
# 产物：dist/AppBox.app

set -euo pipefail

CONFIGURATION="${CONFIGURATION:-release}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="AppBox"
BUNDLE_ID="com.ethicall.appbox"
VERSION="0.1.0"
BUILD_NUMBER="1"
MIN_MACOS="14.0"

DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"

echo "==> 编译（$CONFIGURATION）"
swift build --package-path "$ROOT" -c "$CONFIGURATION" --product "$APP_NAME"

BIN_DIR="$(swift build --package-path "$ROOT" -c "$CONFIGURATION" --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
if [[ ! -x "$BIN" ]]; then
  echo "找不到可执行文件：$BIN" >&2
  exit 1
fi

echo "==> 组装 bundle"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/$APP_NAME"

echo "==> 生成 Info.plist"
# 刻意不设置 LSUIElement：AppBox 是常规应用，保留 Dock 图标作为控制台入口。
cat >"$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>zh_CN</string>
	<key>CFBundleExecutable</key>
	<string>$APP_NAME</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUILD_NUMBER</string>
	<key>LSMinimumSystemVersion</key>
	<string>$MIN_MACOS</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

echo "==> 临时签名（ad-hoc）"
if ! codesign --force --sign - --timestamp=none "$APP" 2>/dev/null; then
  echo "警告：临时签名失败。应用仍可运行，但首次打开可能需要右键→打开来绕过 Gatekeeper。" >&2
fi

echo "==> 完成：$APP"

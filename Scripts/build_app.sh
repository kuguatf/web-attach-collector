#!/bin/bash
# 组装 macOS 应用包：swift build -> 网页附件采集识别工具.app -> ad-hoc 签名
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
APP_NAME="网页附件采集识别工具"
APP_DIR="$ROOT/dist/$APP_NAME.app"

echo "==> 编译：${CONFIG}"
swift build -c "$CONFIG"

BIN="$ROOT/.build/$CONFIG/WebAttachCollector"
if [ ! -f "$BIN" ]; then
    echo "未找到可执行文件：$BIN" >&2
    exit 1
fi

echo "==> 组装 $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN" "$APP_DIR/Contents/MacOS/WebAttachCollector"
cp "$ROOT/Scripts/Info.plist" "$APP_DIR/Contents/Info.plist"
chmod +x "$APP_DIR/Contents/MacOS/WebAttachCollector"

if [ -f "$ROOT/Scripts/AppIcon.icns" ]; then
    cp "$ROOT/Scripts/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP_DIR/Contents/Info.plist" 2>/dev/null || true
fi

echo "==> 签名（ad-hoc）"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --verbose "$APP_DIR"

echo "==> 完成：$APP_DIR"

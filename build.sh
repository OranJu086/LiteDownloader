#!/bin/bash
set -euo pipefail

APP_NAME="简洁下载器"
BUNDLE_ID="com.local.litedownloader"
EXECUTABLE="LiteDownloader"
OUT="dist"
MIN_MACOS="13.0"

cd "$(dirname "$0")"

CACHE="$(mktemp -d)"
trap 'rm -rf "$CACHE"' EXIT

echo "==> 编译 Swift 源码"
mkdir -p build
swiftc -O -parse-as-library -swift-version 5 \
  -target arm64-apple-macosx"$MIN_MACOS" \
  -module-cache-path "$CACHE" \
  Sources/App.swift Sources/ContentView.swift Sources/DownloadEngine.swift \
  -o "build/$EXECUTABLE"

echo "==> 组装 .app 包"
APP="$OUT/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "build/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

echo "==> ad-hoc 签名"
codesign --force --sign - --timestamp=none "$APP"
echo "==> 完成: $APP"

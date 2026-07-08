#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Xiaoyu MacHelper"
APP_VERSION="${APP_VERSION:-1.0}"
APP_BUILD="${APP_BUILD:-1}"
BUILD_DIR="$ROOT_DIR/.build/release"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICON_FILE="$ROOT_DIR/Resources/AppIcon.icns"

cd "$ROOT_DIR"
pkill -x "$APP_NAME" 2>/dev/null || true
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BUILD_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"
cp "$ICON_FILE" "$RESOURCES_DIR/AppIcon.icns"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>Xiaoyu MacHelper</string>
  <key>CFBundleIdentifier</key>
  <string>local.xiaoyu-mac-helper</string>
  <key>CFBundleName</key>
  <string>Xiaoyu MacHelper</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>LSMinimumSystemVersion</key>
  <string>26.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSCameraUsageDescription</key>
  <string>主动视觉感知将在您息屏前使用摄像头进行本地分析，不会存储任何您的信息。</string>
  <key>NSScreenCaptureUsageDescription</key>
  <string>灵动大陆的真实频谱需要临时监听系统播放音频，只用于本地可视化，不会录制、保存或上传音频。</string>
  <key>NSAudioCaptureUsageDescription</key>
  <string>灵动大陆的真实频谱需要临时监听系统播放音频，只用于本地可视化，不会录制、保存或上传音频。</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrefersDisplaySafeAreaCompatibilityMode</key>
  <false/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_DIR"
echo "Built: $APP_DIR"

if [[ "${SKIP_OPEN:-0}" != "1" ]]; then
  open "$APP_DIR"
  echo "Started: $APP_DIR"
fi

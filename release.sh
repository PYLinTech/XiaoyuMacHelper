#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="XiaoyuMacHelper"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
RELEASE_DIR="$ROOT_DIR/release"
STAGING_DIR="$ROOT_DIR/.release-staging"

DEFAULT_APP_VERSION="${APP_VERSION:-1.0}"
DEFAULT_APP_BUILD="${APP_BUILD:-$(date +%y%m%d%H%M)}"

if [[ $# -ge 1 ]]; then
  APP_VERSION="$1"
elif [[ -t 0 ]]; then
  printf "请输入版本号 [%s]: " "$DEFAULT_APP_VERSION"
  read -r INPUT_VERSION
  APP_VERSION="${INPUT_VERSION:-$DEFAULT_APP_VERSION}"
else
  APP_VERSION="$DEFAULT_APP_VERSION"
fi

if [[ $# -ge 2 ]]; then
  APP_BUILD="$2"
elif [[ -t 0 ]]; then
  printf "请输入构建号 [%s]: " "$DEFAULT_APP_BUILD"
  read -r INPUT_BUILD
  APP_BUILD="${INPUT_BUILD:-$DEFAULT_APP_BUILD}"
else
  APP_BUILD="$DEFAULT_APP_BUILD"
fi

if [[ ! "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo "Error: 版本号格式不正确，示例：1.0、1.0.1、2.0" >&2
  exit 1
fi

if [[ ! "$APP_BUILD" =~ ^[0-9]+$ ]]; then
  echo "Error: 构建号必须是纯数字，示例：1、2、100" >&2
  exit 1
fi

export APP_VERSION APP_BUILD
echo "Release version: $APP_VERSION ($APP_BUILD)"

# Release 构建复用 build.sh，避免重复维护编译和 .app 组装逻辑。
SKIP_OPEN=1 "$ROOT_DIR/build.sh"

if [[ ! -d "$APP_DIR" ]]; then
  echo "Error: app not found: $APP_DIR" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist" 2>/dev/null || echo '1.0')"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_DIR/Contents/Info.plist" 2>/dev/null || echo '1')"
DMG_NAME="$APP_NAME-$VERSION-$BUILD.dmg"
DMG_PATH="$RELEASE_DIR/$DMG_NAME"

mkdir -p "$RELEASE_DIR"
rm -rf "$STAGING_DIR" "$DMG_PATH"
mkdir -p "$STAGING_DIR"

# 可选：正式发布时传入 Developer ID 证书重新签名。
# 示例：DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)" ./release.sh
if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  codesign --force --deep --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$APP_DIR"
fi

# DMG 内容：App + Applications 快捷方式，支持用户拖拽安装到应用程序目录。
ditto "$APP_DIR" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

diskutil image create from \
  --volumeName "$APP_NAME" \
  --format UDZO \
  "$STAGING_DIR" \
  "$DMG_PATH"

rm -rf "$STAGING_DIR"

# 可选：签名 DMG。
if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  codesign --force --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$DMG_PATH"
fi

# 可选：公证。优先使用 keychain profile；否则使用 Apple ID 环境变量。
# xcrun notarytool store-credentials "xiaoyu-notary" --apple-id "xxx@example.com" --team-id "TEAMID" --password "app-specific-password"
# NOTARY_PROFILE="xiaoyu-notary" ./release.sh
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"
elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ]]; then
  xcrun notarytool submit "$DMG_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --wait
  xcrun stapler staple "$DMG_PATH"
fi

rm -rf "$ROOT_DIR/dist"
echo "Cleaned: $ROOT_DIR/dist"
echo "Release DMG: $DMG_PATH"

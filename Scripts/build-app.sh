#!/bin/bash
# 构建 + 组装 .app + ad-hoc 签名 + 完整性检查 + 打包 zip
#
# 只依赖 Command Line Tools（不需要完整 Xcode 工程文件）。
# 用法：
#   ./Scripts/build-app.sh              # 构建并打包 dist/CampusNetPilot-<version>-<arch>.zip
#   VERSION=1.2.0 BUILD_NUMBER=42 ./Scripts/build-app.sh
#   ./Scripts/build-app.sh --no-zip     # 只产出 dist/CampusNetPilot.app
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="CampusNetPilot"
BUNDLE_ID="com.example.CampusNetPilot"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
ZIP_PATH="$DIST/${APP_NAME}-${VERSION}-$(uname -m).zip"
MAKE_ZIP=1
[ "${1:-}" = "--no-zip" ] && MAKE_ZIP=0

step() { printf '\n== %s ==\n' "$*"; }
fail() { printf '错误：%s\n' "$*" >&2; exit 1; }

step "0/6 环境检查"
[ "$(uname -s)" = "Darwin" ] || fail "只能在 macOS 上构建（当前：$(uname -s)）。请使用 GitHub Actions 的 macOS runner。"
command -v swift >/dev/null 2>&1 || fail "未找到 swift。请先执行：xcode-select --install"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
[ -n "${SDK_PATH:-}" ] || fail "未找到 macOS SDK。请安装 Command Line Tools 或指定 xcode-select。"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo 0)"
SDK_MAJOR="$(printf '%s' "$SDK_VERSION" | cut -d. -f1)"
[ "${SDK_MAJOR:-0}" -ge 14 ] || fail "macOS SDK 版本为 ${SDK_VERSION}，本项目需要 14.0+（SwiftUI MenuBarExtra / SMAppService）"
swift --version | head -n 2
printf 'SDK: %s (%s)\n主机架构: %s\n' "$SDK_VERSION" "$SDK_PATH" "$(uname -m)"

for tool in codesign plutil lipo ditto shasum; do
  command -v "$tool" >/dev/null 2>&1 || fail "缺少必需工具：$tool"
done

step "1/6 运行核心逻辑测试"
swift test 2>&1 | tail -n 20

step "2/6 构建 release 可执行文件"
swift build -c release --product "$APP_NAME"
BIN_PATH="$(swift build -c release --product "$APP_NAME" --show-bin-path)/$APP_NAME"
[ -f "$BIN_PATH" ] || fail "构建产物不存在：$BIN_PATH"
lipo -info "$BIN_PATH"

step "3/6 组装 $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$APP_NAME"
chmod +x "$APP/Contents/MacOS/$APP_NAME"

sed -e "s/__VERSION__/${VERSION}/g" -e "s/__BUILD__/${BUILD_NUMBER}/g" \
  "$ROOT/Packaging/Info.plist" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE" 2>/dev/null || true
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md" 2>/dev/null || true
plutil -lint "$APP/Contents/Info.plist"

step "4/6 ad-hoc 签名（无 Apple Developer 证书）"
codesign --force --sign - "$APP" 2>&1 || fail "ad-hoc 签名失败"
printf '注意：这是 ad-hoc 签名，未经 Developer ID 签名，也未公证。\n'

step "5/6 完整性检查"
codesign --verify --strict --verbose=2 "$APP"
codesign -dv "$APP" 2>&1 | sed -n '1,8p'
plutil -lint "$APP/Contents/Info.plist"
/usr/bin/file "$APP/Contents/MacOS/$APP_NAME"
printf 'Info.plist 关键字段：\n'
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :NSLocationUsageDescription' "$APP/Contents/Info.plist" >/dev/null
printf 'Gatekeeper 评估（预期被拒，未公证）：\n'
spctl -a -vv "$APP" 2>&1 || true

step "6/6 打包 zip"
if [ "$MAKE_ZIP" -eq 1 ]; then
  rm -f "$ZIP_PATH"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP_PATH"
  shasum -a 256 "$ZIP_PATH" | tee "$ZIP_PATH.sha256"
  printf '\n产物：%s\n' "$ZIP_PATH"
else
  printf '\n产物：%s（未打包）\n' "$APP"
fi

printf '\n完成。首次启动请见 README「首次启动（未公证）」一节。\n'

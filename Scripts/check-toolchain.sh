#!/bin/bash
# 仅依赖 Command Line Tools / Swift 工具链的环境自检。
# 用法：./Scripts/check-toolchain.sh
set -uo pipefail

fail=0
say() { printf '%s\n' "$*"; }
ok() { printf '  [ok] %s\n' "$*"; }
bad() { printf '  [缺少] %s\n' "$*"; fail=1; }

say "== 系统 =="
if [ "$(uname -s)" != "Darwin" ]; then
  bad "当前系统不是 macOS（$(uname -s)）：CampusNetPilot 只能在 macOS 上构建与运行"
  say ""
  say "结论：无法在本机构建。请使用 GitHub Actions 的 macOS runner（见 .github/workflows/build.yml）。"
  exit 1
fi
ok "macOS $(sw_vers -productVersion) ($(uname -m))"

say "== Swift 工具链 =="
if command -v swift >/dev/null 2>&1; then
  ok "$(swift --version 2>&1 | head -n 1)"
else
  bad "swift 未找到；请安装 Xcode Command Line Tools：xcode-select --install"
fi

say "== macOS SDK =="
if command -v xcrun >/dev/null 2>&1; then
  SDK_PATH="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
  SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)"
  if [ -n "${SDK_PATH:-}" ]; then
    ok "SDK ${SDK_VERSION:-unknown} @ ${SDK_PATH}"
    MAJOR="$(printf '%s' "${SDK_VERSION:-0}" | cut -d. -f1)"
    if [ "${MAJOR:-0}" -lt 14 ] 2>/dev/null; then
      bad "macOS SDK 版本过低（需要 14.0+，用于 SwiftUI MenuBarExtra / SMAppService / CoreWLAN 新接口）"
    fi
  else
    bad "找不到 macOS SDK；请执行 xcode-select --install 或 xcode-select -s /Applications/Xcode.app"
  fi
else
  bad "xcrun 未找到；请安装 Command Line Tools"
fi

say "== 打包工具 =="
for tool in codesign plutil lipo ditto shasum; do
  if command -v "$tool" >/dev/null 2>&1; then
    ok "$tool"
  else
    bad "$tool"
  fi
done

say "== 架构 =="
if [ "$(uname -m)" = "arm64" ]; then
  ok "Apple Silicon (arm64)：本机构建产物为 arm64"
else
  say "  [提示] 当前是 $(uname -m)，产物为该架构；arm64 版本请用 GitHub Actions 的 macos-15 runner"
fi

say ""
if [ "$fail" -eq 0 ]; then
  say "结论：工具链齐全，可以执行 ./Scripts/build-app.sh"
  exit 0
else
  say "结论：环境不完整，请按上面的提示补齐后重试。"
  exit 2
fi

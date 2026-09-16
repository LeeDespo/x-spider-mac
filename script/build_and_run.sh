#!/bin/bash
set -euo pipefail

# Build and run XSpiderMac in Debug mode on Apple Silicon macOS.
# Intended as the Codex "Run" button entrypoint and local dev helper.

export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_FILE="${PROJECT_DIR}/XSpiderMac/XSpiderMac.xcodeproj"
DERIVED_DIR="${PROJECT_DIR}/XSpiderMac/build"

mkdir -p "${DERIVED_DIR}"

xcodebuild \
  -project "${PROJECT_FILE}" \
  -scheme XSpiderMac \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "${DERIVED_DIR}/DerivedData" \
  build

APP_PATH="$(find "${DERIVED_DIR}/DerivedData/Build/Products/Debug" -maxdepth 1 -name 'XSpiderMac.app' | head -n 1)"
if [[ -z "${APP_PATH}" ]]; then
  echo "Could not find built XSpiderMac.app" >&2
  exit 1
fi

# 先杀掉所有在跑的实例。`open -n` 会另起一个进程，旧实例（可能来自
# ~/Library/Developer/Xcode/DerivedData 的过期产物）会继续占用窗口与端口，
# 让人误以为"改动没生效"。
pkill -x XSpiderMac 2>/dev/null || true
sleep 1

echo "Launching ${APP_PATH}"
open -n "${APP_PATH}"
echo "运行中的二进制: ${APP_PATH}/Contents/MacOS/XSpiderMac (mtime $(stat -f '%Sm' "${APP_PATH}/Contents/MacOS/XSpiderMac"))"
echo "启动日志会记录 executablePath，可用「帮助 → 打开日志文件夹」核对是否为本次构建。"

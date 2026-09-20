#!/bin/bash
# 打包 Release 版为 DMG（未签名分发）。
#
# 用法：
#   script/package_dmg.sh              # 用 project.yml 里的版本号
#   script/package_dmg.sh 1.0.1        # 指定版本号
#
# 产物：dist/XSpiderMac-<版本>.dmg
#
# 关于签名：本项目**不做**签名与公证（无 Apple 开发者账号）。
# 因此打包时用 `CODE_SIGN_IDENTITY="-"` 做 ad-hoc 签名——
# 这不会通过 Gatekeeper，但能保证 App 内部二进制（含内置 aria2next）
# 在 Apple Silicon 上可执行。用户首次打开需按 README 手动放行。
set -euo pipefail

export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_FILE="${PROJECT_DIR}/XSpiderMac/XSpiderMac.xcodeproj"
BUILD_DIR="${PROJECT_DIR}/XSpiderMac/build"
DIST_DIR="${PROJECT_DIR}/dist"

# 版本号：命令行参数优先，否则从 project.yml 读
VERSION="${1:-$(grep -E '^\s+MARKETING_VERSION:' "${PROJECT_DIR}/XSpiderMac/project.yml" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')}"
if [[ -z "${VERSION}" ]]; then
  echo "无法确定版本号，请显式传入：script/package_dmg.sh 1.0.0" >&2
  exit 1
fi
echo "==> 版本 ${VERSION}"

mkdir -p "${BUILD_DIR}" "${DIST_DIR}"

echo "==> 构建 Release（arm64）"
xcodebuild \
  -project "${PROJECT_FILE}" \
  -scheme XSpiderMac \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "${BUILD_DIR}/DerivedData" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

APP_PATH="$(find "${BUILD_DIR}/DerivedData/Build/Products/Release" -maxdepth 1 -name 'XSpiderMac.app' | head -n 1)"
if [[ -z "${APP_PATH}" ]]; then
  echo "找不到构建产物 XSpiderMac.app" >&2
  exit 1
fi
echo "==> 应用：${APP_PATH}"

# ad-hoc 签名（含内置二进制），保证可执行
echo "==> ad-hoc 签名"
codesign --force --deep --sign - "${APP_PATH}" 2>&1 | tail -2 || true

# 组装 dmg 内容：应用 + 指向 /Applications 的快捷方式
STAGING="$(mktemp -d)"
trap 'rm -rf "${STAGING}"' EXIT
cp -R "${APP_PATH}" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"

DMG_PATH="${DIST_DIR}/XSpiderMac-${VERSION}.dmg"
rm -f "${DMG_PATH}"

echo "==> 生成 dmg"
hdiutil create \
  -volname "X-Spider" \
  -srcfolder "${STAGING}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}" >/dev/null

echo
echo "完成：${DMG_PATH}"
echo "大小：$(du -h "${DMG_PATH}" | cut -f1)"
echo
echo "提醒：dmg 未签名/未公证，用户首次打开需手动放行（见 README「解除系统拦截」）。"

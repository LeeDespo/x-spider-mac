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

echo "Launching ${APP_PATH}"
open -n "${APP_PATH}"

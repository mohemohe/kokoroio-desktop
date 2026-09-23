#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${PROJECT_ROOT}/.build/xcode}"
APP_PATH="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}/KokoroDesktop.app"
XCODEBUILD_ARGS=(
  -project "${PROJECT_ROOT}/KokoroDesktop.xcodeproj"
  -scheme KokoroDesktop
  -configuration "${CONFIGURATION}"
  -destination 'platform=macOS'
  -derivedDataPath "${DERIVED_DATA_PATH}"
)

if [[ "${CONFIGURATION}" == "Release" ]]; then
  # Keep local-package and remote-package modules in the same product directory.
  # Without this override, a plain Release build can fail to import EmojiData.
  APP_PATH="${PROJECT_ROOT}/build/Release/KokoroDesktop.app"
  XCODEBUILD_ARGS+=("CONFIGURATION_BUILD_DIR=${PROJECT_ROOT}/build/Release")
fi

xcodebuild "${XCODEBUILD_ARGS[@]}" build

printf '\nBuilt app: %s\n' "${APP_PATH}"

if [[ "${1:-}" == "--run" ]]; then
  open "${APP_PATH}"
fi

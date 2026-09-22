#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${PROJECT_ROOT}/.build/xcode}"

xcodebuild \
  -project "${PROJECT_ROOT}/KokoroDesktop.xcodeproj" \
  -scheme KokoroDesktop \
  -configuration "${CONFIGURATION}" \
  -destination 'platform=macOS' \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  build

APP_PATH="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}/KokoroDesktop.app"
printf '\nBuilt app: %s\n' "${APP_PATH}"

if [[ "${1:-}" == "--run" ]]; then
  open "${APP_PATH}"
fi

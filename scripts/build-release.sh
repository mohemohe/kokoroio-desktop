#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: VERSION=1.2.3 [BUILD_NUMBER=1] bash scripts/build-release.sh [--signed]

Build a universal macOS app and package it as ZIP and DMG.
By default, the app uses an ad-hoc signature for local builds and CI checks.
--signed requires SIGN_IDENTITY, KEYCHAIN_PATH, and NOTARY_PROFILE, and signs,
notarizes, and staples both the app and DMG for distribution.

Optional paths: DERIVED_DATA_PATH (default: .build/release-xcode)
                OUTPUT_DIR (default: build/release)
EOF
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

SIGNED=false
case "${1:-}" in
  '') ;;
  --signed) SIGNED=true ;;
  --help|-h) usage; exit 0 ;;
  *) usage >&2; exit 1 ;;
esac
[[ $# -le 1 ]] || fail 'Expected at most one argument.'

# SemVer without build metadata. Numeric identifiers must not have leading zeros.
NUMERIC='(0|[1-9][0-9]*)'
PRERELEASE_ID='(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
VERSION_PATTERN="^${NUMERIC}\\.${NUMERIC}\\.${NUMERIC}(-${PRERELEASE_ID}(\\.${PRERELEASE_ID})*)?$"
[[ "${VERSION:-}" =~ $VERSION_PATTERN ]] || fail 'VERSION must be X.Y.Z with an optional SemVer prerelease suffix (for example, 1.2.3-beta.1).'
BUILD_NUMBER="${BUILD_NUMBER:-1}"
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || fail 'BUILD_NUMBER must be a positive integer without leading zeros.'
MARKETING_VERSION="${VERSION%%-*}"

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${PROJECT_ROOT}/.build/release-xcode}"
OUTPUT_DIR="${OUTPUT_DIR:-${PROJECT_ROOT}/build/release}"

SIGNING_SETTINGS=(
  'CODE_SIGN_STYLE=Manual'
  'CODE_SIGN_IDENTITY=-'
  'OTHER_CODE_SIGN_FLAGS=--timestamp=none'
)
if [[ "$SIGNED" == true ]]; then
  [[ "${SIGN_IDENTITY:-}" == 'Developer ID Application: '* ]] || fail 'SIGN_IDENTITY must name a Developer ID Application identity.'
  [[ -n "${KEYCHAIN_PATH:-}" && -f "$KEYCHAIN_PATH" ]] || fail 'KEYCHAIN_PATH must name the keychain containing the signing identity and notary profile.'
  [[ -n "${NOTARY_PROFILE:-}" ]] || fail 'NOTARY_PROFILE is required for --signed.'
  # OTHER_CODE_SIGN_FLAGS is parsed by Xcode, so preserve spaces in this path.
  KEYCHAIN_FLAGS_PATH="${KEYCHAIN_PATH//\\/\\\\}"
  KEYCHAIN_FLAGS_PATH="${KEYCHAIN_FLAGS_PATH//\"/\\\"}"
  SIGNING_SETTINGS=(
    'CODE_SIGN_STYLE=Manual'
    "CODE_SIGN_IDENTITY=${SIGN_IDENTITY}"
    "OTHER_CODE_SIGN_FLAGS=--timestamp --keychain \"${KEYCHAIN_FLAGS_PATH}\""
  )
fi

xcodebuild \
  -project "${PROJECT_ROOT}/KokoroDesktop.xcodeproj" \
  -scheme KokoroDesktop \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  'ARCHS=arm64 x86_64' \
  'ONLY_ACTIVE_ARCH=NO' \
  'ENABLE_APP_SANDBOX=YES' \
  'ENABLE_HARDENED_RUNTIME=YES' \
  'CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO' \
  "MARKETING_VERSION=${MARKETING_VERSION}" \
  "CURRENT_PROJECT_VERSION=${BUILD_NUMBER}" \
  "${SIGNING_SETTINGS[@]}" \
  build

BUILT_APP="${DERIVED_DATA_PATH}/Build/Products/Release/KokoroDesktop.app"
[[ -d "$BUILT_APP" ]] || fail "Build did not produce ${BUILT_APP}."

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kokoro-release.XXXXXX")"
cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

DMG_ROOT="${STAGING_DIR}/dmg"
APP_PATH="${DMG_ROOT}/KokoroDesktop.app"
mkdir -p "$DMG_ROOT"
ditto "$BUILT_APP" "$APP_PATH"

INFO_PLIST="${APP_PATH}/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")" == "$MARKETING_VERSION" ]] || fail 'Built app marketing version does not match VERSION.'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")" == "$BUILD_NUMBER" ]] || fail 'Built app build number does not match BUILD_NUMBER.'
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
# Xcode can inject debugging entitlements even into a Release build. Check both
# slices of the signed app before submitting it to Apple's notarization service.
for ARCH in arm64 x86_64; do
  xcrun lipo "${APP_PATH}/Contents/MacOS/KokoroDesktop" -verify_arch "$ARCH"
  ENTITLEMENTS_PATH="${STAGING_DIR}/entitlements-${ARCH}.plist"
  codesign --display --arch "$ARCH" --entitlements - --xml "$APP_PATH" > "$ENTITLEMENTS_PATH"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$ENTITLEMENTS_PATH")" == true ]] || fail "Built app (${ARCH}) is missing its sandbox entitlement."
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.network.client' "$ENTITLEMENTS_PATH")" == true ]] || fail "Built app (${ARCH}) is missing its outgoing network entitlement."
  GET_TASK_ALLOW="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$ENTITLEMENTS_PATH" 2>/dev/null || true)"
  [[ "$GET_TASK_ALLOW" != true ]] || fail "Built app (${ARCH}) enables com.apple.security.get-task-allow; distribution builds must disable debugging entitlements."
  SIGNATURE_DETAILS="$(codesign --display --arch "$ARCH" --verbose=4 "$APP_PATH" 2>&1)"
  [[ "$SIGNATURE_DETAILS" =~ flags=[^[:space:]]*runtime ]] || fail "Built app (${ARCH}) does not enable the hardened runtime."
  if [[ "$SIGNED" == true ]]; then
    [[ "$SIGNATURE_DETAILS" == *"Authority=${SIGN_IDENTITY}"* ]] || fail "Built app (${ARCH}) is not signed with the requested Developer ID identity."
    [[ "$SIGNATURE_DETAILS" == *'Timestamp='* ]] || fail "Built app (${ARCH}) is missing a secure signing timestamp."
  fi
done

notarize() {
  local artifact="$1"
  local label="$2"
  local result_file="${STAGING_DIR}/notary-${label}.json"
  local submit_exit=0
  local status
  local submission_id

  xcrun notarytool submit "$artifact" \
    --keychain-profile "$NOTARY_PROFILE" \
    --keychain "$KEYCHAIN_PATH" \
    --wait --output-format json > "$result_file" || submit_exit=$?
  cat "$result_file"
  status="$(plutil -extract status raw -o - "$result_file" 2>/dev/null || true)"
  if [[ "$submit_exit" -ne 0 || "$status" != Accepted ]]; then
    submission_id="$(plutil -extract id raw -o - "$result_file" 2>/dev/null || true)"
    if [[ -n "$submission_id" ]]; then
      xcrun notarytool log "$submission_id" \
        --keychain-profile "$NOTARY_PROFILE" \
        --keychain "$KEYCHAIN_PATH" || true
    fi
    fail "Notarization of ${label} was not accepted (status: ${status:-unknown})."
  fi
}

if [[ "$SIGNED" == true ]]; then
  ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "${STAGING_DIR}/app-notary.zip"
  notarize "${STAGING_DIR}/app-notary.zip" app
  xcrun stapler staple "$APP_PATH"
  xcrun stapler validate "$APP_PATH"
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
fi

ARTIFACT_NAME="KokoroDesktop-${VERSION}-universal"
ZIP_PATH="${STAGING_DIR}/${ARTIFACT_NAME}.zip"
DMG_PATH="${STAGING_DIR}/${ARTIFACT_NAME}.dmg"
# The published ZIP must contain the stapled app, not the notarization input.
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
ln -s /Applications "${DMG_ROOT}/Applications"
hdiutil create \
  -volname 'Kokoro Desktop' \
  -srcfolder "$DMG_ROOT" \
  -format UDZO \
  -fs HFS+ \
  "$DMG_PATH"

if [[ "$SIGNED" == true ]]; then
  codesign --sign "$SIGN_IDENTITY" --keychain "$KEYCHAIN_PATH" --timestamp "$DMG_PATH"
  codesign --verify --strict --verbose=2 "$DMG_PATH"
  notarize "$DMG_PATH" dmg
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  codesign --verify --strict --verbose=2 "$DMG_PATH"
fi

(
  cd "$STAGING_DIR"
  shasum -a 256 "${ARTIFACT_NAME}.zip" "${ARTIFACT_NAME}.dmg" > SHA256SUMS.txt
)
mkdir -p "$OUTPUT_DIR"
cp "$ZIP_PATH" "$DMG_PATH" "${STAGING_DIR}/SHA256SUMS.txt" "$OUTPUT_DIR/"
printf '\nRelease artifacts: %s\n' "$OUTPUT_DIR"

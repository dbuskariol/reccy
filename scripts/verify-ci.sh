#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/reccy-release.sh"

DERIVED_DATA="${RECCY_CI_DERIVED_DATA:-$ROOT_DIR/.build/CIDerivedData}"

while IFS= read -r -d '' script; do
  /bin/bash -n "$script"
done < <(/usr/bin/find "$ROOT_DIR/scripts" -type f -name '*.sh' -print0)
/usr/bin/xcrun swiftc -typecheck "$ROOT_DIR/scripts/sparkle-public-key.swift"
/usr/bin/plutil -lint "$ROOT_DIR/Configuration/Reccy-Info.plist" >/dev/null
/usr/bin/plutil -lint "$ROOT_DIR/Reccy/Reccy.entitlements" >/dev/null
/usr/bin/plutil -lint "$ROOT_DIR/Reccy/ReccyDebug.entitlements" >/dev/null
/usr/bin/plutil -lint "$ROOT_DIR/Reccy/PrivacyInfo.xcprivacy" >/dev/null
/usr/bin/git -C "$ROOT_DIR" diff --check
reccy_assert_release_metadata "$ROOT_DIR" >/dev/null

/usr/bin/xcodebuild \
  -project "$ROOT_DIR/Reccy.xcodeproj" \
  -scheme Reccy \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  test
/usr/bin/xcodebuild \
  -project "$ROOT_DIR/Reccy.xcodeproj" \
  -scheme Reccy \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  CLANG_ENABLE_CODE_COVERAGE=NO \
  GCC_GENERATE_TEST_COVERAGE_FILES=NO \
  GCC_INSTRUMENT_PROGRAM_FLOW_ARCS=NO \
  CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=NO \
  build

UNSIGNED_APP="$DERIVED_DATA/Build/Products/Release/Reccy.app"
[[ -d "$UNSIGNED_APP" ]] || reccy_fail "CI release app was not produced at $UNSIGNED_APP"
INFO="$UNSIGNED_APP/Contents/Info.plist"
[[ "$(reccy_plist_value CFBundleIdentifier "$INFO")" == "$RECCY_EXPECTED_BUNDLE_ID" ]] \
  || reccy_fail 'CI release has an unexpected bundle identifier'
[[ "$(reccy_plist_value LSMinimumSystemVersion "$INFO")" == "$RECCY_EXPECTED_MINIMUM_SYSTEM" ]] \
  || reccy_fail 'CI release has an unexpected deployment target'
[[ "$(reccy_plist_value SUFeedURL "$INFO")" == "$RECCY_EXPECTED_FEED_URL" ]] \
  || reccy_fail 'CI release has an unexpected Sparkle feed URL'
[[ -f "$UNSIGNED_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" ]] \
  || reccy_fail 'CI release is missing Sparkle'
PRIVACY_MANIFEST="$UNSIGNED_APP/Contents/Resources/PrivacyInfo.xcprivacy"
[[ -f "$PRIVACY_MANIFEST" ]] || reccy_fail 'CI release is missing its privacy manifest'
/usr/bin/plutil -lint "$PRIVACY_MANIFEST" >/dev/null \
  || reccy_fail 'CI release contains an invalid privacy manifest'
[[ "$(reccy_plist_value NSPrivacyTracking "$PRIVACY_MANIFEST")" == "false" ]] \
  || reccy_fail 'CI release unexpectedly declares tracking'
[[ "$(/usr/bin/plutil -extract NSPrivacyCollectedDataTypes raw -o - "$PRIVACY_MANIFEST")" == "0" ]] \
  || reccy_fail 'CI release unexpectedly declares collected data'

ARCHITECTURES="$(/usr/bin/lipo -archs "$UNSIGNED_APP/Contents/MacOS/Reccy")"
for architecture in "${RECCY_EXPECTED_ARCHITECTURES[@]}"; do
  [[ " $ARCHITECTURES " == *" $architecture "* ]] \
    || reccy_fail "CI release is missing $architecture (found: $ARCHITECTURES)"
done

reccy_note 'CI verification passed'

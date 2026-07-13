#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${RECCY_DERIVED_DATA:-$ROOT_DIR/.build/ReleaseDerivedData}"
OUTPUT_DIR="${RECCY_OUTPUT_DIR:-$ROOT_DIR/dist}"
BUILT_APP="$DERIVED_DATA/Build/Products/Release/Reccy.app"
OUTPUT_APP="$OUTPUT_DIR/Reccy.app"

XCODE_ARGS=(
  -project "$ROOT_DIR/Reccy.xcodeproj"
  -scheme Reccy
  -configuration Release
  -destination "generic/platform=macOS"
  -derivedDataPath "$DERIVED_DATA"
  CLANG_ENABLE_CODE_COVERAGE=NO
  GCC_GENERATE_TEST_COVERAGE_FILES=NO
  GCC_INSTRUMENT_PROGRAM_FLOW_ARCS=NO
)

if [[ -n "${RECCY_CODESIGN_IDENTITY:-}" ]]; then
  XCODE_ARGS+=(
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY="$RECCY_CODESIGN_IDENTITY"
  )
fi
if [[ -n "${RECCY_DEVELOPMENT_TEAM:-}" ]]; then
  XCODE_ARGS+=(DEVELOPMENT_TEAM="$RECCY_DEVELOPMENT_TEAM")
fi

/usr/bin/xcodebuild "${XCODE_ARGS[@]}" clean build

[[ -d "$BUILT_APP" ]] || {
  printf 'Release app was not produced at %s\n' "$BUILT_APP" >&2
  exit 1
}

/bin/mkdir -p "$OUTPUT_DIR"
/bin/rm -rf "$OUTPUT_APP"
/usr/bin/ditto "$BUILT_APP" "$OUTPUT_APP"

/usr/bin/codesign --verify --strict --deep --verbose=2 "$OUTPUT_APP"
/usr/bin/plutil -lint "$OUTPUT_APP/Contents/Info.plist" >/dev/null

if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$OUTPUT_APP/Contents/Info.plist")" != "com.reccy.mac" ]]; then
  printf 'Release app has an unexpected bundle identifier.\n' >&2
  exit 1
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$OUTPUT_APP/Contents/Info.plist")" != "26.0" ]]; then
  printf 'Release app must require macOS 26.0.\n' >&2
  exit 1
fi
if [[ ! -f "$OUTPUT_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" ]]; then
  printf 'Release app is missing the embedded Sparkle framework.\n' >&2
  exit 1
fi

ARCHITECTURES="$(/usr/bin/lipo -archs "$OUTPUT_APP/Contents/MacOS/Reccy")"
for architecture in arm64 x86_64; do
  [[ " $ARCHITECTURES " == *" $architecture "* ]] || {
    printf 'Release app is missing the %s architecture. Found: %s\n' "$architecture" "$ARCHITECTURES" >&2
    exit 1
  }
done

if [[ "${RECCY_REQUIRE_DEVELOPER_ID:-0}" == "1" ]]; then
  SIGNING_DETAILS="$(/usr/bin/codesign -dvv "$OUTPUT_APP" 2>&1)"
  /usr/bin/grep -q '^Authority=Developer ID Application:' <<<"$SIGNING_DETAILS" || {
    printf 'A Developer ID Application signature is required.\n' >&2
    exit 1
  }
  /usr/bin/grep -Eq '^TeamIdentifier=.+$' <<<"$SIGNING_DETAILS" || {
    printf 'The Developer ID signature is missing its team identifier.\n' >&2
    exit 1
  }
fi

printf 'Built %s\n' "$OUTPUT_APP"

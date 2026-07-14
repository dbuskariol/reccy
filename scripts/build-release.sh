#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/reccy-release.sh"

DERIVED_DATA="${RECCY_DERIVED_DATA:-$(reccy_default_derived_data Release)}"
OUTPUT_DIR="${RECCY_OUTPUT_DIR:-$ROOT_DIR/dist}"
ARCHIVE_PATH="${RECCY_ARCHIVE_PATH:-$OUTPUT_DIR/Reccy.xcarchive}"
BUILT_APP="$ARCHIVE_PATH/Products/Applications/Reccy.app"
EXPORT_PATH="${RECCY_EXPORT_PATH:-$OUTPUT_DIR/export}"
EXPORTED_APP="$EXPORT_PATH/Reccy.app"
EXPORT_OPTIONS_PLIST="$OUTPUT_DIR/DeveloperIDExportOptions.plist"
OUTPUT_APP="$OUTPUT_DIR/Reccy.app"
SIGNING_IDENTITY="${RECCY_CODESIGN_IDENTITY:-}"

if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(reccy_find_developer_id_identity)"
fi
[[ -n "$SIGNING_IDENTITY" ]] || reccy_fail 'no Developer ID Application signing identity is available'

reccy_note "Archiving a universal Developer ID release with $SIGNING_IDENTITY"
/bin/mkdir -p "$OUTPUT_DIR"
/bin/rm -rf "$ARCHIVE_PATH"

XCODE_ARGS=(
  -project "$ROOT_DIR/Reccy.xcodeproj"
  -scheme Reccy
  -configuration Release
  -destination "generic/platform=macOS"
  -derivedDataPath "$DERIVED_DATA"
  -archivePath "$ARCHIVE_PATH"
  CLANG_ENABLE_CODE_COVERAGE=NO
  GCC_GENERATE_TEST_COVERAGE_FILES=NO
  GCC_INSTRUMENT_PROGRAM_FLOW_ARCS=NO
  CODE_SIGN_STYLE=Manual
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY"
)

if [[ -n "${RECCY_DEVELOPMENT_TEAM:-}" ]]; then
  XCODE_ARGS+=(DEVELOPMENT_TEAM="$RECCY_DEVELOPMENT_TEAM")
fi
if [[ "${RECCY_VERBOSE_BUILD:-0}" != "1" ]]; then
  XCODE_ARGS=(-quiet "${XCODE_ARGS[@]}")
fi

/usr/bin/xcodebuild "${XCODE_ARGS[@]}" clean archive

[[ -d "$BUILT_APP" ]] || reccy_fail "release app was not archived at $BUILT_APP"

ARCHIVED_TEAM="$(reccy_signature_team "$BUILT_APP")"
[[ -n "$ARCHIVED_TEAM" && "$ARCHIVED_TEAM" != "not set" ]] \
  || reccy_fail 'the archived app signature is missing its team identifier'
if [[ -n "${RECCY_DEVELOPMENT_TEAM:-}" && "$ARCHIVED_TEAM" != "$RECCY_DEVELOPMENT_TEAM" ]]; then
  reccy_fail "archive team $ARCHIVED_TEAM does not match expected team $RECCY_DEVELOPMENT_TEAM"
fi

# Exporting is a required distribution step, not a redundant copy. Xcode
# re-signs every nested Sparkle helper in the correct inside-out order with the
# selected Developer ID identity and secure timestamp.
/bin/rm -rf "$EXPORT_PATH"
/bin/rm -f "$EXPORT_OPTIONS_PLIST"
/usr/bin/plutil -create xml1 "$EXPORT_OPTIONS_PLIST"
/usr/bin/plutil -insert method -string developer-id "$EXPORT_OPTIONS_PLIST"
/usr/bin/plutil -insert signingStyle -string manual "$EXPORT_OPTIONS_PLIST"
/usr/bin/plutil -insert teamID -string "$ARCHIVED_TEAM" "$EXPORT_OPTIONS_PLIST"
/usr/bin/plutil -insert signingCertificate -string "$SIGNING_IDENTITY" "$EXPORT_OPTIONS_PLIST"

EXPORT_ARGS=(
  -exportArchive
  -archivePath "$ARCHIVE_PATH"
  -exportPath "$EXPORT_PATH"
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"
)
if [[ "${RECCY_VERBOSE_BUILD:-0}" != "1" ]]; then
  EXPORT_ARGS=(-quiet "${EXPORT_ARGS[@]}")
fi
/usr/bin/xcodebuild "${EXPORT_ARGS[@]}"

[[ -d "$EXPORTED_APP" ]] || reccy_fail "Developer ID export did not produce $EXPORTED_APP"
/bin/rm -rf "$OUTPUT_APP"
/usr/bin/ditto "$EXPORTED_APP" "$OUTPUT_APP"
reccy_assert_release_app "$OUTPUT_APP" "${RECCY_DEVELOPMENT_TEAM:-}"

DSYM="$ARCHIVE_PATH/dSYMs/Reccy.app.dSYM"
if [[ -d "$DSYM" ]]; then
  VERSION="$(reccy_plist_value CFBundleShortVersionString "$OUTPUT_APP/Contents/Info.plist")"
  BUILD="$(reccy_plist_value CFBundleVersion "$OUTPUT_APP/Contents/Info.plist")"
  SYMBOLS_DIR="$OUTPUT_DIR/symbols"
  SYMBOLS_ARCHIVE="$SYMBOLS_DIR/Reccy-$VERSION-$BUILD.dSYM.zip"
  /bin/mkdir -p "$SYMBOLS_DIR"
  /bin/rm -f "$SYMBOLS_ARCHIVE"
  /usr/bin/ditto -c -k --keepParent "$DSYM" "$SYMBOLS_ARCHIVE"
else
  reccy_fail 'the release archive did not contain Reccy.app.dSYM'
fi

reccy_note "Built and verified $OUTPUT_APP"
reccy_note "Archived debug symbols at $SYMBOLS_ARCHIVE"

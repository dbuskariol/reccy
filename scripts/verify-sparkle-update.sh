#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/reccy-release.sh"

APP="${1:-$ROOT_DIR/dist/Reccy.app}"
UPDATES_DIR="${2:-$ROOT_DIR/dist/updates}"
APPCAST="$UPDATES_DIR/appcast.xml"
DERIVED_DATA="${RECCY_DERIVED_DATA:-$(reccy_default_derived_data Release)}"
REPOSITORY="$RECCY_EXPECTED_GITHUB_REPOSITORY"
DOWNLOAD_PREFIX="https://github.com/$REPOSITORY/releases/latest/download/"

fail() {
  printf 'Sparkle verification failed: %s\n' "$1" >&2
  exit 1
}
plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$2" 2>/dev/null || true
}
xml_value() {
  /usr/bin/xmllint --xpath "string($1)" "$APPCAST" 2>/dev/null || true
}

[[ -d "$APP" ]] || fail "missing app bundle $APP"
[[ -f "$APPCAST" ]] || fail "missing appcast $APPCAST"
reccy_assert_release_app "$APP" "${RECCY_DEVELOPMENT_TEAM:-}"
if [[ "${RECCY_ALLOW_UNNOTARIZED_PACKAGE:-0}" != "1" ]]; then
  reccy_assert_notarized_app "$APP"
fi
reccy_assert_sparkle_signing_key "$ROOT_DIR" "$APP" "$DERIVED_DATA"

INFO="$APP/Contents/Info.plist"
BUNDLE_ID="$(plist_value CFBundleIdentifier "$INFO")"
SHORT_VERSION="$(plist_value CFBundleShortVersionString "$INFO")"
BUILD_VERSION="$(plist_value CFBundleVersion "$INFO")"
FEED_URL="$(plist_value SUFeedURL "$INFO")"
PUBLIC_KEY="$(plist_value SUPublicEDKey "$INFO")"
MINIMUM_SYSTEM="$(plist_value LSMinimumSystemVersion "$INFO")"

[[ "$BUNDLE_ID" == "com.reccy.mac" ]] || fail "unexpected bundle identifier $BUNDLE_ID"
[[ "$MINIMUM_SYSTEM" == "26.0" ]] || fail "minimum system must be 26.0"
[[ "$FEED_URL" == "${DOWNLOAD_PREFIX}appcast.xml" ]] || fail "unexpected feed URL $FEED_URL"
[[ "$PUBLIC_KEY" =~ ^[A-Za-z0-9+/=]{40,}$ ]] || fail 'invalid Sparkle public key'

BASE_NAME="Reccy-$SHORT_VERSION-$BUILD_VERSION"
ARCHIVE="$UPDATES_DIR/$BASE_NAME.zip"
NOTES="$UPDATES_DIR/$BASE_NAME.md"
[[ -f "$ARCHIVE" ]] || fail "missing archive $ARCHIVE"
[[ -f "$NOTES" ]] || fail "missing release notes $NOTES"
/usr/bin/unzip -tqq "$ARCHIVE" || fail 'update archive is not readable'

ARCHIVE_LIST="$(/usr/bin/unzip -Z1 "$ARCHIVE")"
for path in \
  'Reccy.app/Contents/Info.plist' \
  'Reccy.app/Contents/MacOS/Reccy' \
  'Reccy.app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle'
do
  /usr/bin/grep -Fxq "$path" <<<"$ARCHIVE_LIST" || fail "archive is missing $path"
done

ITEM_COUNT="$(/usr/bin/xmllint --xpath 'count(/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="item"])' "$APPCAST" 2>/dev/null || true)"
[[ "${ITEM_COUNT%.*}" -ge 1 ]] || fail 'appcast has no update items'

APPCAST_SHORT_VERSION="$(xml_value '/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="item"][1]/*[local-name()="shortVersionString"]')"
APPCAST_BUILD_VERSION="$(xml_value '/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="item"][1]/*[local-name()="version"]')"
APPCAST_MINIMUM_SYSTEM="$(xml_value '/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="item"][1]/*[local-name()="minimumSystemVersion"]')"
APPCAST_URL="$(xml_value '/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="item"][1]/*[local-name()="enclosure"][1]/@url')"
APPCAST_LENGTH="$(xml_value '/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="item"][1]/*[local-name()="enclosure"][1]/@length')"
APPCAST_SIGNATURE="$(xml_value '/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="item"][1]/*[local-name()="enclosure"][1]/@*[local-name()="edSignature"]')"
RELEASE_NOTES_URL="$(xml_value '/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="item"][1]/*[local-name()="releaseNotesLink"]')"
RELEASE_NOTES_LENGTH="$(xml_value '/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="item"][1]/*[local-name()="releaseNotesLink"]/@*[local-name()="length"]')"
RELEASE_NOTES_SIGNATURE="$(xml_value '/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="item"][1]/*[local-name()="releaseNotesLink"]/@*[local-name()="edSignature"]')"

[[ "$APPCAST_SHORT_VERSION" == "$SHORT_VERSION" ]] || fail 'appcast short version mismatch'
[[ "$APPCAST_BUILD_VERSION" == "$BUILD_VERSION" ]] || fail 'appcast build version mismatch'
[[ "$APPCAST_MINIMUM_SYSTEM" == "26.0" ]] || fail 'appcast minimum system mismatch'
[[ "$APPCAST_URL" == "$DOWNLOAD_PREFIX$BASE_NAME.zip" ]] || fail 'appcast archive URL mismatch'
[[ "$APPCAST_LENGTH" == "$(/usr/bin/stat -f%z "$ARCHIVE")" ]] || fail 'appcast archive length mismatch'
[[ "$APPCAST_SIGNATURE" =~ ^[A-Za-z0-9+/=]{40,}$ ]] || fail 'appcast is missing an EdDSA signature'
[[ "$RELEASE_NOTES_URL" == "$DOWNLOAD_PREFIX$BASE_NAME.md" ]] || fail 'appcast release notes URL mismatch'
[[ "$RELEASE_NOTES_LENGTH" == "$(/usr/bin/stat -f%z "$NOTES")" ]] || fail 'appcast release notes length mismatch'
[[ "$RELEASE_NOTES_SIGNATURE" =~ ^[A-Za-z0-9+/=]{40,}$ ]] || fail 'release notes are missing an EdDSA signature'

SIGN_UPDATE="$(reccy_resolve_sparkle_tool "$ROOT_DIR" "$DERIVED_DATA" sign_update)"
VERIFY_KEY_ARGS=(--account "${RECCY_SPARKLE_KEY_ACCOUNT:-ed25519}")
if [[ -n "${RECCY_SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
  VERIFY_KEY_ARGS=(--ed-key-file "$RECCY_SPARKLE_PRIVATE_KEY_FILE")
fi
"$SIGN_UPDATE" --verify "${VERIFY_KEY_ARGS[@]}" "$ARCHIVE" "$APPCAST_SIGNATURE" >/dev/null \
  || fail 'Sparkle rejected the update archive signature'
"$SIGN_UPDATE" --verify "${VERIFY_KEY_ARGS[@]}" "$NOTES" "$RELEASE_NOTES_SIGNATURE" >/dev/null \
  || fail 'Sparkle rejected the release notes signature'
"$SIGN_UPDATE" --verify "${VERIFY_KEY_ARGS[@]}" "$APPCAST" >/dev/null \
  || fail 'Sparkle rejected the signed appcast'

EXTRACTED_DIR="$(/usr/bin/mktemp -d -t reccy-update.XXXXXX)"
trap '/bin/rm -rf "$EXTRACTED_DIR"' EXIT
/usr/bin/ditto -x -k "$ARCHIVE" "$EXTRACTED_DIR"
EXTRACTED_APP="$EXTRACTED_DIR/Reccy.app"
reccy_assert_release_app "$EXTRACTED_APP" "${RECCY_DEVELOPMENT_TEAM:-}"
if [[ "${RECCY_ALLOW_UNNOTARIZED_PACKAGE:-0}" != "1" ]]; then
  reccy_assert_notarized_app "$EXTRACTED_APP"
fi

APP_HASH="$(/usr/bin/shasum -a 256 "$APP/Contents/MacOS/Reccy" | /usr/bin/awk '{print $1}')"
EXTRACTED_HASH="$(/usr/bin/shasum -a 256 "$EXTRACTED_APP/Contents/MacOS/Reccy" | /usr/bin/awk '{print $1}')"
[[ "$APP_HASH" == "$EXTRACTED_HASH" ]] || fail 'archive executable differs from the verified app'

printf 'Verified %s and its signed Sparkle feed.\n' "$BASE_NAME"

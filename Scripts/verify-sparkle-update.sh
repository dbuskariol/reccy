#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT_DIR/dist/Reccy.app}"
UPDATES_DIR="${2:-$ROOT_DIR/dist/updates}"
APPCAST="$UPDATES_DIR/appcast.xml"
REPOSITORY="${RECCY_GITHUB_REPOSITORY:-dbuskariol/reccy}"
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

[[ "$APPCAST_SHORT_VERSION" == "$SHORT_VERSION" ]] || fail 'appcast short version mismatch'
[[ "$APPCAST_BUILD_VERSION" == "$BUILD_VERSION" ]] || fail 'appcast build version mismatch'
[[ "$APPCAST_MINIMUM_SYSTEM" == "26.0" ]] || fail 'appcast minimum system mismatch'
[[ "$APPCAST_URL" == "$DOWNLOAD_PREFIX$BASE_NAME.zip" ]] || fail 'appcast archive URL mismatch'
[[ "$APPCAST_LENGTH" == "$(/usr/bin/stat -f%z "$ARCHIVE")" ]] || fail 'appcast archive length mismatch'
[[ "$APPCAST_SIGNATURE" =~ ^[A-Za-z0-9+/=]{40,}$ ]] || fail 'appcast is missing an EdDSA signature'

/usr/bin/codesign --verify --strict --deep --verbose=2 "$APP"
ARCHITECTURES="$(/usr/bin/lipo -archs "$APP/Contents/MacOS/Reccy")"
[[ " $ARCHITECTURES " == *' arm64 '* ]] || fail 'release app is missing arm64'
[[ " $ARCHITECTURES " == *' x86_64 '* ]] || fail 'release app is missing x86_64'
if [[ "${RECCY_REQUIRE_DEVELOPER_ID:-0}" == "1" ]]; then
  SIGNING_DETAILS="$(/usr/bin/codesign -dvv "$APP" 2>&1)"
  /usr/bin/grep -q '^Authority=Developer ID Application:' <<<"$SIGNING_DETAILS" || fail 'Developer ID signature missing'
  /usr/bin/xcrun stapler validate "$APP" >/dev/null || fail 'stapled notarization ticket missing'
  /usr/sbin/spctl --assess --type execute "$APP" || fail 'Gatekeeper rejected the app'
fi

printf 'Verified %s and its signed Sparkle feed.\n' "$BASE_NAME"

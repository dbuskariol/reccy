#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/Scripts/lib/reccy-release.sh"

APP="${RECCY_RELEASE_APP:-$ROOT_DIR/dist/Reccy.app}"
UPDATES_DIR="${RECCY_UPDATES_DIR:-$ROOT_DIR/dist/updates}"
INFO="$APP/Contents/Info.plist"

reccy_assert_release_app "$APP" "${RECCY_DEVELOPMENT_TEAM:-}"
if [[ "${RECCY_ALLOW_UNNOTARIZED_PACKAGE:-0}" != "1" ]]; then
  reccy_assert_notarized_app "$APP"
fi
"$ROOT_DIR/Scripts/verify-sparkle-update.sh" "$APP" "$UPDATES_DIR"

VERSION="$(reccy_plist_value CFBundleShortVersionString "$INFO")"
BUILD="$(reccy_plist_value CFBundleVersion "$INFO")"
TEAM="$(reccy_signature_team "$APP")"
BASE_NAME="Reccy-$VERSION-$BUILD"
ARCHIVE="$UPDATES_DIR/$BASE_NAME.zip"
NOTES="$UPDATES_DIR/$BASE_NAME.md"
APPCAST="$UPDATES_DIR/appcast.xml"
SYMBOLS="$ROOT_DIR/dist/symbols/$BASE_NAME.dSYM.zip"
CHECKSUMS="$UPDATES_DIR/SHA256SUMS"
MANIFEST="$UPDATES_DIR/release.json"
MANIFEST_PLIST="$UPDATES_DIR/.release-manifest.plist"

for artifact in "$ARCHIVE" "$NOTES" "$APPCAST"; do
  [[ -f "$artifact" ]] || reccy_fail "release artifact is missing: $artifact"
done

(
  cd "$UPDATES_DIR"
  /usr/bin/shasum -a 256 "$(basename "$ARCHIVE")" "$(basename "$NOTES")" "$(basename "$APPCAST")" >"$CHECKSUMS"
  /usr/bin/shasum -a 256 -c "$CHECKSUMS" >/dev/null
)

/bin/rm -f "$MANIFEST" "$MANIFEST_PLIST"
/usr/bin/plutil -create xml1 "$MANIFEST_PLIST"
trap '/bin/rm -f "$MANIFEST_PLIST"' EXIT
/usr/bin/plutil -insert schemaVersion -integer 1 "$MANIFEST_PLIST"
/usr/bin/plutil -insert product -string Reccy "$MANIFEST_PLIST"
/usr/bin/plutil -insert bundleIdentifier -string "$RECCY_EXPECTED_BUNDLE_ID" "$MANIFEST_PLIST"
/usr/bin/plutil -insert version -string "$VERSION" "$MANIFEST_PLIST"
/usr/bin/plutil -insert build -string "$BUILD" "$MANIFEST_PLIST"
/usr/bin/plutil -insert minimumSystemVersion -string "$RECCY_EXPECTED_MINIMUM_SYSTEM" "$MANIFEST_PLIST"
/usr/bin/plutil -insert teamIdentifier -string "$TEAM" "$MANIFEST_PLIST"
/usr/bin/plutil -insert gitCommit -string "$(/usr/bin/git -C "$ROOT_DIR" rev-parse HEAD)" "$MANIFEST_PLIST"
/usr/bin/plutil -insert createdAt -string "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" "$MANIFEST_PLIST"

/usr/bin/plutil -insert archive -dictionary "$MANIFEST_PLIST"
/usr/bin/plutil -insert archive.name -string "$(basename "$ARCHIVE")" "$MANIFEST_PLIST"
/usr/bin/plutil -insert archive.bytes -integer "$(/usr/bin/stat -f%z "$ARCHIVE")" "$MANIFEST_PLIST"
/usr/bin/plutil -insert archive.sha256 -string "$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{print $1}')" "$MANIFEST_PLIST"

/usr/bin/plutil -insert appcast -dictionary "$MANIFEST_PLIST"
/usr/bin/plutil -insert appcast.name -string "$(basename "$APPCAST")" "$MANIFEST_PLIST"
/usr/bin/plutil -insert appcast.sha256 -string "$(/usr/bin/shasum -a 256 "$APPCAST" | /usr/bin/awk '{print $1}')" "$MANIFEST_PLIST"

if [[ -f "$SYMBOLS" ]]; then
  /usr/bin/plutil -insert debugSymbols -dictionary "$MANIFEST_PLIST"
  /usr/bin/plutil -insert debugSymbols.name -string "$(basename "$SYMBOLS")" "$MANIFEST_PLIST"
  /usr/bin/plutil -insert debugSymbols.sha256 -string "$(/usr/bin/shasum -a 256 "$SYMBOLS" | /usr/bin/awk '{print $1}')" "$MANIFEST_PLIST"
fi

/usr/bin/plutil -convert json -r -o "$MANIFEST" "$MANIFEST_PLIST"
/usr/bin/plutil -convert json -o - "$MANIFEST" >/dev/null
reccy_note "Created checksums and release manifest in $UPDATES_DIR"

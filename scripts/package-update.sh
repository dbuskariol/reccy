#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/reccy-release.sh"

APP="$ROOT_DIR/dist/Reccy.app"
UPDATES_DIR="$ROOT_DIR/dist/updates"
NOTES_SOURCE="${RECCY_RELEASE_NOTES_FILE:-$ROOT_DIR/Documentation/RELEASE_NOTES.md}"

if [[ "${RECCY_SKIP_BUILD:-0}" != "1" ]]; then
  "$ROOT_DIR/scripts/build-release.sh"
fi

[[ -d "$APP" ]] || reccy_fail "app bundle not found: $APP"
[[ -f "$NOTES_SOURCE" ]] || reccy_fail "release notes not found: $NOTES_SOURCE"
reccy_assert_release_app "$APP" "${RECCY_DEVELOPMENT_TEAM:-}"
if [[ "${RECCY_ALLOW_UNNOTARIZED_PACKAGE:-0}" != "1" ]]; then
  reccy_assert_notarized_app "$APP"
fi

SHORT_VERSION="$(reccy_plist_value CFBundleShortVersionString "$APP/Contents/Info.plist")"
BUILD_VERSION="$(reccy_plist_value CFBundleVersion "$APP/Contents/Info.plist")"
BASE_NAME="Reccy-$SHORT_VERSION-$BUILD_VERSION"
ARCHIVE="$UPDATES_DIR/$BASE_NAME.zip"
NOTES="$UPDATES_DIR/$BASE_NAME.md"

[[ "$(/usr/bin/sed -n '1p' "$NOTES_SOURCE")" == "# Reccy $SHORT_VERSION" ]] \
  || reccy_fail "release notes do not match Reccy $SHORT_VERSION"

/bin/mkdir -p "$UPDATES_DIR"
/bin/rm -f "$ARCHIVE" "$NOTES"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
/bin/cp "$NOTES_SOURCE" "$NOTES"
/usr/bin/unzip -tqq "$ARCHIVE" || reccy_fail 'the generated update archive is unreadable'

reccy_note "Packaged $ARCHIVE"

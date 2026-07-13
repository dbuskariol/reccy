#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT_DIR/dist/Reccy.app"
UPDATES_DIR="$ROOT_DIR/dist/updates"
NOTES_SOURCE="${RECCY_RELEASE_NOTES_FILE:-$ROOT_DIR/Documentation/RELEASE_NOTES.md}"

if [[ "${RECCY_SKIP_BUILD:-0}" != "1" ]]; then
  "$ROOT_DIR/Scripts/build-release.sh"
fi

[[ -d "$APP" ]] || {
  printf 'App bundle not found: %s\n' "$APP" >&2
  exit 1
}
[[ -f "$NOTES_SOURCE" ]] || {
  printf 'Release notes not found: %s\n' "$NOTES_SOURCE" >&2
  exit 1
}

/usr/bin/codesign --verify --strict --deep --verbose=2 "$APP"
SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
BASE_NAME="Reccy-$SHORT_VERSION-$BUILD_VERSION"
ARCHIVE="$UPDATES_DIR/$BASE_NAME.zip"
NOTES="$UPDATES_DIR/$BASE_NAME.md"

/bin/mkdir -p "$UPDATES_DIR"
/bin/rm -f "$ARCHIVE" "$NOTES"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
/bin/cp "$NOTES_SOURCE" "$NOTES"

printf 'Packaged %s\n' "$ARCHIVE"

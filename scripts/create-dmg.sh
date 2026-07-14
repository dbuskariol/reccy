#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/reccy-release.sh"

APP="${RECCY_DMG_APP:-$ROOT_DIR/dist/Reccy.app}"
UPDATES_DIR="${RECCY_DMG_OUTPUT_DIR:-$ROOT_DIR/dist/updates}"
NOTARY_OUTPUT_DIR="${RECCY_NOTARY_OUTPUT_DIR:-$ROOT_DIR/dist/notarization}"
PREPARE_ONLY="${RECCY_NOTARY_PREPARE_ONLY:-0}"
SIGNING_IDENTITY="${RECCY_CODESIGN_IDENTITY:-}"

if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(reccy_find_developer_id_identity)"
fi
[[ -n "$SIGNING_IDENTITY" ]] || reccy_fail 'no Developer ID Application signing identity is available'
reccy_assert_release_app "$APP" "${RECCY_DEVELOPMENT_TEAM:-}"
if [[ "$PREPARE_ONLY" != "1" ]]; then
  reccy_assert_notarized_app "$APP"
fi

VERSION="$(reccy_plist_value CFBundleShortVersionString "$APP/Contents/Info.plist")"
BUILD="$(reccy_plist_value CFBundleVersion "$APP/Contents/Info.plist")"
BASE_NAME="Reccy-$VERSION-$BUILD"
DISK_IMAGE="$UPDATES_DIR/$BASE_NAME.dmg"
SUBMISSION_JSON="$NOTARY_OUTPUT_DIR/notary-submit-dmg-$VERSION-$BUILD.json"
LOG_JSON="$NOTARY_OUTPUT_DIR/notary-log-dmg-$VERSION-$BUILD.json"
STAGING_DIR="$(/usr/bin/mktemp -d -t reccy-dmg-stage.XXXXXX)"
MOUNT_POINT="$(/usr/bin/mktemp -d -t reccy-dmg-mount.XXXXXX)"
IS_MOUNTED=0

cleanup() {
  if [[ "$IS_MOUNTED" == "1" ]]; then
    /usr/bin/hdiutil detach "$MOUNT_POINT" -quiet || true
  fi
  /bin/rm -rf "$STAGING_DIR" "$MOUNT_POINT"
}
trap cleanup EXIT INT TERM

/bin/mkdir -p "$UPDATES_DIR" "$NOTARY_OUTPUT_DIR"
/usr/bin/ditto "$APP" "$STAGING_DIR/Reccy.app"
/bin/ln -s /Applications "$STAGING_DIR/Applications"
/bin/rm -f "$DISK_IMAGE" "$SUBMISSION_JSON" "$LOG_JSON"

reccy_note "Creating compressed disk image $DISK_IMAGE"
/usr/bin/hdiutil create \
  -quiet \
  -ov \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=9 \
  -volname "Reccy $VERSION" \
  -srcfolder "$STAGING_DIR" \
  "$DISK_IMAGE"
/usr/bin/codesign --sign "$SIGNING_IDENTITY" --timestamp "$DISK_IMAGE"
reccy_assert_signed_disk_image "$DISK_IMAGE" "${RECCY_DEVELOPMENT_TEAM:-}"

if [[ "$PREPARE_ONLY" != "1" ]]; then
  reccy_note 'Submitting the signed disk image to Apple notarization'
  reccy_submit_notarization "$DISK_IMAGE" "$SUBMISSION_JSON" "$LOG_JSON"
  /usr/bin/xcrun stapler staple "$DISK_IMAGE"
  reccy_assert_notarized_disk_image "$DISK_IMAGE" "${RECCY_DEVELOPMENT_TEAM:-}"
fi

/usr/bin/hdiutil attach \
  -quiet \
  -readonly \
  -nobrowse \
  -mountpoint "$MOUNT_POINT" \
  "$DISK_IMAGE"
IS_MOUNTED=1
[[ -d "$MOUNT_POINT/Reccy.app" ]] || reccy_fail 'the disk image does not contain Reccy.app'
[[ -L "$MOUNT_POINT/Applications" ]] || reccy_fail 'the disk image does not contain the Applications shortcut'
[[ "$(/usr/bin/readlink "$MOUNT_POINT/Applications")" == "/Applications" ]] \
  || reccy_fail 'the disk image Applications shortcut has an unexpected destination'
reccy_assert_release_app "$MOUNT_POINT/Reccy.app" "${RECCY_DEVELOPMENT_TEAM:-}"
if [[ "$PREPARE_ONLY" != "1" ]]; then
  reccy_assert_notarized_app "$MOUNT_POINT/Reccy.app"
fi

SOURCE_HASH="$(/usr/bin/shasum -a 256 "$APP/Contents/MacOS/Reccy" | /usr/bin/awk '{print $1}')"
MOUNTED_HASH="$(/usr/bin/shasum -a 256 "$MOUNT_POINT/Reccy.app/Contents/MacOS/Reccy" | /usr/bin/awk '{print $1}')"
[[ "$SOURCE_HASH" == "$MOUNTED_HASH" ]] \
  || reccy_fail 'the disk image app executable differs from the verified release app'
/usr/bin/hdiutil detach "$MOUNT_POINT" -quiet
IS_MOUNTED=0

if [[ "$PREPARE_ONLY" == "1" ]]; then
  reccy_note "Prepared signed disk image $DISK_IMAGE without contacting Apple"
else
  reccy_note "Created and verified notarized disk image $DISK_IMAGE"
fi

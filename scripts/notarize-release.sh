#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/reccy-release.sh"

APP="${RECCY_NOTARY_APP:-$ROOT_DIR/dist/Reccy.app}"
OUTPUT_DIR="${RECCY_NOTARY_OUTPUT_DIR:-$ROOT_DIR/dist/notarization}"
PREPARE_ONLY="${RECCY_NOTARY_PREPARE_ONLY:-0}"

reccy_assert_release_app "$APP" "${RECCY_DEVELOPMENT_TEAM:-}"

SHORT_VERSION="$(reccy_plist_value CFBundleShortVersionString "$APP/Contents/Info.plist")"
BUILD_VERSION="$(reccy_plist_value CFBundleVersion "$APP/Contents/Info.plist")"
ARCHIVE="$OUTPUT_DIR/Reccy-$SHORT_VERSION-$BUILD_VERSION-notarization.zip"
SUBMISSION_JSON="$OUTPUT_DIR/notary-submit-app-$SHORT_VERSION-$BUILD_VERSION.json"
LOG_JSON="$OUTPUT_DIR/notary-log-app-$SHORT_VERSION-$BUILD_VERSION.json"

/bin/mkdir -p "$OUTPUT_DIR"
/bin/rm -f "$ARCHIVE" "$SUBMISSION_JSON" "$LOG_JSON"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"

if [[ "$PREPARE_ONLY" == "1" ]]; then
  /usr/bin/unzip -tqq "$ARCHIVE" || reccy_fail 'the notarization archive is unreadable'
  RECCY_NOTARY_PREPARE_ONLY=1 "$ROOT_DIR/scripts/create-dmg.sh"
  reccy_note "Prepared $ARCHIVE"
  exit 0
fi

reccy_note 'Submitting the signed app to Apple notarization'
reccy_submit_notarization "$ARCHIVE" "$SUBMISSION_JSON" "$LOG_JSON"

/usr/bin/xcrun stapler staple "$APP"
reccy_assert_release_app "$APP" "${RECCY_DEVELOPMENT_TEAM:-}"
reccy_assert_notarized_app "$APP"

RECCY_SKIP_BUILD=1 "$ROOT_DIR/scripts/package-update.sh"
"$ROOT_DIR/scripts/generate-appcast.sh"
"$ROOT_DIR/scripts/create-dmg.sh"

reccy_note "Notarized, stapled, and packaged $APP"

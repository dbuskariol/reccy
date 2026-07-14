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
SUBMISSION_JSON="$OUTPUT_DIR/notary-submit-$SHORT_VERSION-$BUILD_VERSION.json"
LOG_JSON="$OUTPUT_DIR/notary-log-$SHORT_VERSION-$BUILD_VERSION.json"

/bin/mkdir -p "$OUTPUT_DIR"
/bin/rm -f "$ARCHIVE" "$SUBMISSION_JSON" "$LOG_JSON"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"

if [[ "$PREPARE_ONLY" == "1" ]]; then
  /usr/bin/unzip -tqq "$ARCHIVE" || reccy_fail 'the notarization archive is unreadable'
  reccy_note "Prepared $ARCHIVE"
  exit 0
fi

NOTARY_ARGS=()
if [[ -n "${RECCY_NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  NOTARY_ARGS=(--keychain-profile "$RECCY_NOTARY_KEYCHAIN_PROFILE")
elif [[ -n "${RECCY_NOTARY_KEY_PATH:-}" \
  && -n "${RECCY_NOTARY_KEY_ID:-}" \
  && -n "${RECCY_NOTARY_ISSUER_ID:-}" ]]; then
  NOTARY_ARGS=(
    --key "$RECCY_NOTARY_KEY_PATH"
    --key-id "$RECCY_NOTARY_KEY_ID"
    --issuer "$RECCY_NOTARY_ISSUER_ID"
  )
else
  /bin/cat >&2 <<'EOF'
Notarization credentials are not configured. Use a stored Keychain profile:

  RECCY_NOTARY_KEYCHAIN_PROFILE="Reccy Notary" scripts/notarize-release.sh

CI may instead provide RECCY_NOTARY_KEY_PATH, RECCY_NOTARY_KEY_ID, and
RECCY_NOTARY_ISSUER_ID. Passwords and Apple IDs are never accepted inline.
EOF
  exit 1
fi

reccy_note 'Submitting the signed app to Apple notarization'
/usr/bin/xcrun notarytool submit "$ARCHIVE" "${NOTARY_ARGS[@]}" --wait --output-format json > "$SUBMISSION_JSON"
SUBMISSION_ID="$(/usr/bin/plutil -extract id raw -o - "$SUBMISSION_JSON" 2>/dev/null || true)"
STATUS="$(/usr/bin/plutil -extract status raw -o - "$SUBMISSION_JSON" 2>/dev/null || true)"

if [[ -n "$SUBMISSION_ID" ]]; then
  /usr/bin/xcrun notarytool log "$SUBMISSION_ID" "${NOTARY_ARGS[@]}" --output-format json > "$LOG_JSON" || true
fi
[[ "$STATUS" == "Accepted" ]] || {
  reccy_fail "notarization failed with status ${STATUS:-unknown}; inspect $LOG_JSON"
}

/usr/bin/xcrun stapler staple "$APP"
reccy_assert_release_app "$APP" "${RECCY_DEVELOPMENT_TEAM:-}"
reccy_assert_notarized_app "$APP"

RECCY_SKIP_BUILD=1 "$ROOT_DIR/scripts/package-update.sh"
"$ROOT_DIR/scripts/generate-appcast.sh"

reccy_note "Notarized, stapled, and packaged $APP"

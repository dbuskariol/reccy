#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${RECCY_NOTARY_APP:-$ROOT_DIR/dist/Reccy.app}"
OUTPUT_DIR="${RECCY_NOTARY_OUTPUT_DIR:-$ROOT_DIR/dist/notarization}"
PREPARE_ONLY="${RECCY_NOTARY_PREPARE_ONLY:-0}"

[[ -d "$APP" ]] || {
  printf 'App bundle not found: %s\n' "$APP" >&2
  exit 1
}
/usr/bin/codesign --verify --strict --deep --verbose=2 "$APP"

SIGNING_DETAILS="$(/usr/bin/codesign -dvv "$APP" 2>&1)"
/usr/bin/grep -q '^Authority=Developer ID Application:' <<<"$SIGNING_DETAILS" || {
  printf 'Notarization requires a Developer ID Application signature.\n' >&2
  exit 1
}

SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
ARCHIVE="$OUTPUT_DIR/Reccy-$SHORT_VERSION-$BUILD_VERSION-notarization.zip"
SUBMISSION_JSON="$OUTPUT_DIR/notary-submit-$SHORT_VERSION-$BUILD_VERSION.json"
LOG_JSON="$OUTPUT_DIR/notary-log-$SHORT_VERSION-$BUILD_VERSION.json"

/bin/mkdir -p "$OUTPUT_DIR"
/bin/rm -f "$ARCHIVE" "$SUBMISSION_JSON" "$LOG_JSON"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"

if [[ "$PREPARE_ONLY" == "1" ]]; then
  printf 'Prepared %s\n' "$ARCHIVE"
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
  cat >&2 <<'EOF'
Notarization credentials are not configured. Use a stored Keychain profile:

  RECCY_NOTARY_KEYCHAIN_PROFILE="Reccy Notary" Scripts/notarize-release.sh

CI may instead provide RECCY_NOTARY_KEY_PATH, RECCY_NOTARY_KEY_ID, and
RECCY_NOTARY_ISSUER_ID. Passwords and Apple IDs are never accepted inline.
EOF
  exit 1
fi

/usr/bin/xcrun notarytool submit "$ARCHIVE" "${NOTARY_ARGS[@]}" --wait --output-format json > "$SUBMISSION_JSON"
SUBMISSION_ID="$(/usr/bin/plutil -extract id raw -o - "$SUBMISSION_JSON" 2>/dev/null || true)"
STATUS="$(/usr/bin/plutil -extract status raw -o - "$SUBMISSION_JSON" 2>/dev/null || true)"

if [[ -n "$SUBMISSION_ID" ]]; then
  /usr/bin/xcrun notarytool log "$SUBMISSION_ID" "${NOTARY_ARGS[@]}" --output-format json > "$LOG_JSON" || true
fi
[[ "$STATUS" == "Accepted" ]] || {
  printf 'Notarization failed with status %s.\n' "${STATUS:-unknown}" >&2
  exit 1
}

/usr/bin/xcrun stapler staple "$APP"
/usr/bin/xcrun stapler validate "$APP"
/usr/sbin/spctl --assess --type execute --verbose=4 "$APP"

RECCY_SKIP_BUILD=1 "$ROOT_DIR/Scripts/package-update.sh"
"$ROOT_DIR/Scripts/generate-appcast.sh"

printf 'Notarized, stapled, and packaged %s\n' "$APP"

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/reccy-release.sh"

DERIVED_DATA="${RECCY_DERIVED_DATA:-$(reccy_default_derived_data Development)}"
INSTALL_PATH="${RECCY_INSTALL_PATH:-/Applications/Reccy.app}"
BUILT_APP="$DERIVED_DATA/Build/Products/Debug/Reccy.app"
SIGNING_IDENTITY="${RECCY_CODESIGN_IDENTITY:-}"

if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null \
    | /usr/bin/awk -F\" '/Apple Development|Developer ID Application/ { print $2; exit }')"
fi

if [[ -z "$SIGNING_IDENTITY" ]]; then
  /bin/cat >&2 <<'MESSAGE'
Reccy needs a stable Apple code-signing identity for development installs.

No Apple Development or Developer ID Application certificate is available in
this login keychain. Ad-hoc installation is intentionally refused because each
rebuild changes the app identity and invalidates Screen Recording and
Microphone privacy grants.

One-time setup:
  1. Open Xcode → Settings → Accounts and add your Apple Account.
  2. Select the account's team and choose Manage Certificates.
  3. Create or install an Apple Development certificate.
  4. Run scripts/install-development.sh again.

Use Developer ID Application for release artifacts; the local development
installer accepts Apple Development so TCC recognizes rebuilt apps consistently.
MESSAGE
  exit 2
fi

XCODE_ARGS=(
  -project "$ROOT_DIR/Reccy.xcodeproj"
  -scheme Reccy
  -configuration Debug
  -destination "platform=macOS"
  -derivedDataPath "$DERIVED_DATA"
  CODE_SIGN_STYLE=Manual
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY"
)
if [[ -n "${RECCY_DEVELOPMENT_TEAM:-}" ]]; then
  XCODE_ARGS+=(DEVELOPMENT_TEAM="$RECCY_DEVELOPMENT_TEAM")
fi
if [[ "${RECCY_VERBOSE_BUILD:-0}" != "1" ]]; then
  XCODE_ARGS=(-quiet "${XCODE_ARGS[@]}")
fi

printf 'Building Reccy with %s\n' "$SIGNING_IDENTITY"
/usr/bin/xcodebuild "${XCODE_ARGS[@]}" build

[[ -d "$BUILT_APP" ]] || {
  printf 'Development app was not produced at %s\n' "$BUILT_APP" >&2
  exit 1
}
/usr/bin/codesign --verify --strict --deep --verbose=2 "$BUILT_APP"

INFO="$BUILT_APP/Contents/Info.plist"
[[ "$(reccy_plist_value CFBundleIdentifier "$INFO")" == "$RECCY_EXPECTED_BUNDLE_ID" ]] \
  || reccy_fail 'development app has an unexpected bundle identifier'
[[ "$(reccy_plist_value LSMinimumSystemVersion "$INFO")" == "$RECCY_EXPECTED_MINIMUM_SYSTEM" ]] \
  || reccy_fail "development app must require macOS $RECCY_EXPECTED_MINIMUM_SYSTEM"

SIGNING_DETAILS="$(/usr/bin/codesign -dvv "$BUILT_APP" 2>&1)"
/usr/bin/grep -Eq '^Authority=(Apple Development|Developer ID Application):' <<<"$SIGNING_DETAILS" || {
  printf 'The built app does not have an Apple Development or Developer ID signature.\n' >&2
  exit 1
}
NEW_TEAM="$(/usr/bin/awk -F= '/^TeamIdentifier=/{print $2; exit}' <<<"$SIGNING_DETAILS")"
[[ -n "$NEW_TEAM" && "$NEW_TEAM" != "not set" ]] || {
  printf 'The built app signature is missing its team identifier.\n' >&2
  exit 1
}

if [[ -d "$INSTALL_PATH" ]]; then
  CURRENT_DETAILS="$(/usr/bin/codesign -dvv "$INSTALL_PATH" 2>&1 || true)"
  CURRENT_TEAM="$(/usr/bin/awk -F= '/^TeamIdentifier=/{print $2; exit}' <<<"$CURRENT_DETAILS")"
  if [[ -n "$CURRENT_TEAM" && "$CURRENT_TEAM" != "not set" && "$CURRENT_TEAM" != "$NEW_TEAM" ]]; then
    printf 'Refusing to replace a Reccy install signed by a different team (%s).\n' "$CURRENT_TEAM" >&2
    exit 1
  fi

  CURRENT_REQUIREMENT="$(/usr/bin/codesign -d -r- "$INSTALL_PATH" 2>&1 | /usr/bin/sed -n 's/^designated => //p')"
  NEW_REQUIREMENT="$(/usr/bin/codesign -d -r- "$BUILT_APP" 2>&1 | /usr/bin/sed -n 's/^designated => //p')"
  if [[ -n "$CURRENT_REQUIREMENT" && "$CURRENT_REQUIREMENT" != "$NEW_REQUIREMENT" \
    && "${RECCY_ALLOW_IDENTITY_MIGRATION:-0}" != "1" ]]; then
    reccy_fail 'the installed app has a different designated requirement; refusing an identity change that would invalidate privacy grants'
  fi
fi

STAGING_PATH="$(dirname "$INSTALL_PATH")/.Reccy.installing.$$.app"
BACKUP_PATH="$(dirname "$INSTALL_PATH")/.Reccy.previous.$$.app"
cleanup_install() {
  [[ -z "${STAGING_PATH:-}" ]] || /bin/rm -rf "$STAGING_PATH"
  if [[ -n "${BACKUP_PATH:-}" && -d "$BACKUP_PATH" ]]; then
    if [[ ! -d "$INSTALL_PATH" ]]; then
      /bin/mv "$BACKUP_PATH" "$INSTALL_PATH"
    else
      /bin/rm -rf "$BACKUP_PATH"
    fi
  fi
}
trap cleanup_install EXIT INT TERM
/bin/rm -rf "$STAGING_PATH"
/usr/bin/ditto "$BUILT_APP" "$STAGING_PATH"
/usr/bin/codesign --verify --strict --deep --verbose=2 "$STAGING_PATH"

/usr/bin/osascript -e 'tell application id "com.reccy.mac" to quit' 2>/dev/null || true
for _ in 1 2 3 4 5; do
  /usr/bin/pgrep -x Reccy >/dev/null 2>&1 || break
  /bin/sleep 1
done
/usr/bin/pkill -TERM -x Reccy 2>/dev/null || true

/bin/rm -rf "$BACKUP_PATH"
if [[ -d "$INSTALL_PATH" ]]; then
  /bin/mv "$INSTALL_PATH" "$BACKUP_PATH"
fi
if ! /bin/mv "$STAGING_PATH" "$INSTALL_PATH"; then
  [[ ! -d "$BACKUP_PATH" ]] || /bin/mv "$BACKUP_PATH" "$INSTALL_PATH"
  reccy_fail 'unable to atomically install the new app'
fi
STAGING_PATH=""
/bin/rm -rf "$BACKUP_PATH"
BACKUP_PATH=""
/usr/bin/codesign --verify --strict --deep --verbose=2 "$INSTALL_PATH"
/usr/bin/open -n "$INSTALL_PATH"

printf 'Installed %s\n' "$INSTALL_PATH"
printf 'Team identifier: %s\n' "$NEW_TEAM"
printf 'Grant capture permissions once; subsequent installs retain the same verified designated app identity.\n'

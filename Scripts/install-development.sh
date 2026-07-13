#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${RECCY_DERIVED_DATA:-$ROOT_DIR/.build/DevelopmentDerivedData}"
INSTALL_PATH="${RECCY_INSTALL_PATH:-/Applications/Reccy.app}"
BUILT_APP="$DERIVED_DATA/Build/Products/Debug/Reccy.app"
SIGNING_IDENTITY="${RECCY_CODESIGN_IDENTITY:-}"

if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null \
    | /usr/bin/awk -F\" '/Apple Development|Developer ID Application/ { print $2; exit }')"
fi

if [[ -z "$SIGNING_IDENTITY" ]]; then
  cat >&2 <<'MESSAGE'
Reccy needs a stable Apple code-signing identity for development installs.

No Apple Development or Developer ID Application certificate is available in
this login keychain. Ad-hoc installation is intentionally refused because each
rebuild changes the app identity and invalidates Screen Recording and
Microphone privacy grants.

One-time setup:
  1. Open Xcode → Settings → Accounts and add your Apple Account.
  2. Select the account's team and choose Manage Certificates.
  3. Create or install an Apple Development certificate.
  4. Run Scripts/install-development.sh again.

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

printf 'Building Reccy with %s\n' "$SIGNING_IDENTITY"
/usr/bin/xcodebuild "${XCODE_ARGS[@]}" build

[[ -d "$BUILT_APP" ]] || {
  printf 'Development app was not produced at %s\n' "$BUILT_APP" >&2
  exit 1
}
/usr/bin/codesign --verify --strict --deep --verbose=2 "$BUILT_APP"

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
fi

STAGING_PATH="$(dirname "$INSTALL_PATH")/.Reccy.installing.$$.app"
/bin/rm -rf "$STAGING_PATH"
/usr/bin/ditto "$BUILT_APP" "$STAGING_PATH"
/usr/bin/codesign --verify --strict --deep --verbose=2 "$STAGING_PATH"

/usr/bin/pkill -x Reccy 2>/dev/null || true
/bin/rm -rf "$INSTALL_PATH"
/bin/mv "$STAGING_PATH" "$INSTALL_PATH"
/usr/bin/open -n -a "$INSTALL_PATH"

printf 'Installed %s\n' "$INSTALL_PATH"
printf 'Team identifier: %s\n' "$NEW_TEAM"
printf 'Grant capture permissions once; subsequent installs signed by this team keep the same app identity.\n'
